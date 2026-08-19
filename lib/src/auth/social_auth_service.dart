import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

import '../api/platform_repository.dart';
import '../errors/platform_errors.dart';
import '../models/platform_models.dart';

/// The `code` + `state` pair a social-login callback carries.
///
/// Deliberately has NO token fields. There is nothing here for a caller to
/// opportunistically use if a stale backend still appends `access_token` to the
/// callback URL — the tokens are simply never read.
@immutable
class SocialCallback {
  const SocialCallback({required this.code, required this.state});

  /// The single-use, audience-bound authorization code (60s TTL).
  final String code;

  /// The state value echoed back by the server, for CSRF comparison.
  final String? state;

  @override
  String toString() => 'SocialCallback(code: <redacted>, state: <redacted>)';
}

/// Drives the consumer social-login OAuth flow using [flutter_web_auth_2],
/// which presents the provider's authorization page in an
/// `ASWebAuthenticationSession` (iOS/macOS), Chrome Custom Tab (Android), or a
/// popup (Web). It works uniformly on web, mobile and desktop.
///
/// The backend delivers an authorization CODE on the callback, which this
/// service exchanges over POST for the token pair in a response BODY.
///
/// It used to receive `access_token` + `refresh_token` as query parameters.
/// That leaked tokens into browser history, Referer headers and proxy logs.
/// See AOID (SDK-08 / D6) and eden-platform-go.
/// Gate: test/aoid/no_tokens_in_callback_gate_test.dart.
///
/// Wire contract, taken verbatim from eden-platform-go:
///
/// - callback: `<redirect_uri>?code=<handoff>&state=<state>`
/// - exchange: `POST /auth/social/exchange`,
///   `Content-Type: application/x-www-form-urlencoded`,
///   body `code=<handoff>&redirect_uri=<the EXACT target the code was minted for>`
/// - success: `200` `application/json` `{"access_token":"…","refresh_token":"…"}`
/// - failure: `400` `text/plain` `invalid request`; non-POST returns `405`.
///
/// The code is single-use, expires in 60 seconds, and is bound to the exact
/// `redirect_uri` it was delivered to. The server reads it with
/// `r.PostFormValue`, so a code supplied in a query string is refused by
/// design — it must never re-enter a request line.
class SocialAuthService {
  SocialAuthService({
    required PlatformRepository? repository,
    required String baseUrl,
    required String callbackScheme,
    http.Client? httpClient,
  }) : _repository = repository,
       _baseUrl = baseUrl,
       _callbackScheme = _validateScheme(callbackScheme),
       _http = httpClient ?? http.Client();

  final PlatformRepository? _repository;
  final String _baseUrl;
  final String _callbackScheme;
  final http.Client _http;

  /// The dart-define that supplies [callbackScheme].
  static const String schemeEnvVar = 'SOCIAL_CALLBACK_SCHEME';

  /// Path of the exchange endpoint added by eden-platform-go.
  static const String exchangePath = '/auth/social/exchange';

  /// Reads the custom URL scheme from the compile-time environment, mirroring
  /// how this package already resolves `API_BASE_URL`.
  ///
  /// Fails fast when unset. A shared library imported by 18 apps cannot guess a
  /// per-app bundle identifier — this used to be hardcoded to one developer's
  /// personal bundle id, which meant every consumer's mobile callback claimed
  /// to be that app.
  static String callbackSchemeFromEnvironment() {
    const value = String.fromEnvironment(schemeEnvVar, defaultValue: '');
    return _validateScheme(value);
  }

  static String _validateScheme(String scheme) {
    final trimmed = scheme.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        scheme,
        'callbackScheme',
        'A social-login callback scheme is REQUIRED and has no default. '
            'Pass `callbackScheme:` explicitly, or build with '
            '--dart-define=$schemeEnvVar=<your.bundle.id>. '
            'A shared library cannot guess a per-app bundle identifier: this '
            'value must be the custom URL scheme registered in YOUR native '
            'shells (iOS Info.plist CFBundleURLSchemes, Android '
            'AndroidManifest intent-filter).',
      );
    }
    if (trimmed.contains('://') || trimmed.contains('/')) {
      throw ArgumentError.value(
        scheme,
        'callbackScheme',
        'Expected a bare URL scheme (e.g. "ai.aocyber.myapp"), not a URI. '
            'The "://auth/social/callback" suffix is appended for you. '
            'Configure via --dart-define=$schemeEnvVar=<your.bundle.id>.',
      );
    }
    if (trimmed.contains(RegExp(r'\s'))) {
      throw ArgumentError.value(
        scheme,
        'callbackScheme',
        'A URL scheme cannot contain whitespace. '
            'Configure via --dart-define=$schemeEnvVar=<your.bundle.id>.',
      );
    }
    return trimmed;
  }

  /// Initiates social login for [provider] (`google` | `apple` | `microsoft`
  /// | `facebook` | `x`) and returns the resulting [PlatformSession].
  ///
  /// Flow: ask the backend for the provider authorization URL → open the
  /// browser session → read the authorization CODE off the callback → POST it
  /// to the exchange endpoint → take the token pair from the response body.
  Future<PlatformSession> authenticate(String provider) async {
    final repository = _repository;
    if (repository == null) {
      throw StateError(
        'SocialAuthService.authenticate requires a PlatformRepository. '
        'It was constructed with repository: null, which is only valid for '
        'the completeCallback/parse helpers.',
      );
    }

    final redirectUri = _buildRedirectUri();
    final authUrl = await repository.initiateSocialLogin(provider, redirectUri);

    // Bind the callback to THIS authorization request. The server mints the
    // state and embeds it in the authorization URL; it echoes the same value on
    // the callback. Comparing them is what makes a forged callback useless.
    final expectedState = stateFromAuthUrl(authUrl);

    final callbackUrl = await FlutterWebAuth2.authenticate(
      url: authUrl,
      // Web uses the `auth.html` callback page (scheme is `https`); mobile and
      // desktop rejoin the app via the configured custom scheme.
      callbackUrlScheme: kIsWeb ? 'https' : _callbackScheme,
    );

    return completeCallback(
      callbackUrl: callbackUrl,
      redirectUri: redirectUri,
      expectedState: expectedState,
    );
  }

  /// Resolve the redirect URI the server should send the user back to.
  String _buildRedirectUri() {
    String origin;
    try {
      origin = Uri.base.origin;
    } catch (_) {
      // `Uri.base.origin` throws on non-http(s) schemes (e.g. a `file://` or
      // custom-scheme host). Fall back to empty so the web branch fails fast
      // below rather than producing a relative `/auth.html`.
      origin = '';
    }
    return redirectUriFor(
      isWeb: kIsWeb,
      webOrigin: origin,
      callbackScheme: _callbackScheme,
    );
  }

  /// Pure helper: build the platform-appropriate OAuth redirect URI.
  ///
  /// - Web: `${origin}/auth.html` — the callback page flutter_web_auth_2 reads
  ///   on the web platform. This MUST stay a real page at the site root and not
  ///   become a Flutter route: both aoid/portal and aodex/flutter use Flutter's
  ///   default HASH url strategy, so a fragment-routed callback would never
  ///   reach the server.
  ///
  ///   On web the authorization code transits `localStorage` briefly, by
  ///   construction and unavoidably: `url_launcher_web` opens the popup with
  ///   `noopener,noreferrer`, so `window.opener` is null and flutter_web_auth_2
  ///   falls back to polling `localStorage['flutter-web-auth-2']`, removing the
  ///   entry within a second. A PKCE-bound, single-use, 60-second code there is
  ///   materially better than a refresh token — which is exactly why NOBODY may
  ///   "improve" `auth.html` by adding token parameters to it.
  ///
  /// - Mobile/desktop: the `<callbackScheme>://auth/social/callback` deep link.
  static String redirectUriFor({
    required bool isWeb,
    required String webOrigin,
    required String callbackScheme,
  }) {
    if (isWeb) {
      if (webOrigin.isEmpty) {
        throw AuthError(
          'Cannot build a web social-login redirect URI: the page origin is '
          'empty. A relative "/auth.html" would be rejected by AOID with a '
          'confusing invalid_request, because redirect URIs are exact-matched.',
        );
      }
      return '$webOrigin/auth.html';
    }
    return '${_validateScheme(callbackScheme)}://auth/social/callback';
  }

  /// Pure helper: extract the `state` the server embedded in the authorization
  /// URL, so the callback's echoed state can be compared against it.
  static String? stateFromAuthUrl(String authUrl) {
    try {
      return Uri.parse(authUrl).queryParameters['state'];
    } catch (_) {
      return null;
    }
  }

  /// Pure helper: parse a social-login callback URL into its `code` + `state`.
  ///
  /// Reads ONLY `code`, `state` and `error`. Any `access_token` /
  /// `refresh_token` a not-yet-redeployed backend still appends is ignored
  /// outright — a client that opportunistically used them would keep the leak
  /// alive for every consumer that has not redeployed.
  static SocialCallback parseCallbackUrl(String callbackUrl) {
    final uri = Uri.parse(callbackUrl);

    // the spec appends the query INSIDE the fragment for a fragment-shaped
    // redirect_uri (`https://host/#/auth/complete?code=…`), which is what a
    // hash-routed SPA router parses. Uri.queryParameters is empty in that case,
    // so fall back to the fragment's own query string.
    var params = uri.queryParameters;
    if (!params.containsKey('code') && uri.fragment.contains('?')) {
      final fragmentQuery = uri.fragment.substring(
        uri.fragment.indexOf('?') + 1,
      );
      params = Uri.splitQueryString(fragmentQuery);
    }

    final error = params['error'];
    if (error != null && error.isNotEmpty) {
      throw AuthError('Social login failed: $error');
    }

    final code = params['code'];
    if (code == null || code.isEmpty) {
      throw AuthError(
        'Social login callback carried no authorization code. The backend must '
        'redirect with ?code=<handoff>&state=<state>. '
        'A callback carrying tokens instead of a code is REFUSED, not used.',
      );
    }

    return SocialCallback(code: code, state: params['state']);
  }

  /// Verify the callback, then exchange its authorization code for the token
  /// pair and build the [PlatformSession].
  ///
  /// [redirectUri] must byte-match the target the code was minted for — that is
  /// the code's audience binding, not a formality.
  ///
  /// State is compared BEFORE any network call: a forged callback must not even
  /// reach the exchange endpoint.
  Future<PlatformSession> completeCallback({
    required String callbackUrl,
    required String redirectUri,
    String? expectedState,
  }) async {
    final callback = parseCallbackUrl(callbackUrl);

    if (expectedState != null) {
      if (callback.state == null || callback.state != expectedState) {
        throw AuthError(
          'Social login state mismatch — the callback did not come from the '
          'authorization request this client started. No code was exchanged.',
        );
      }
    }

    return _exchange(code: callback.code, redirectUri: redirectUri);
  }

  /// POST the authorization code to the exchange endpoint and read the token
  /// pair out of the JSON response BODY.
  Future<PlatformSession> _exchange({
    required String code,
    required String redirectUri,
  }) async {
    final base = _baseUrl.endsWith('/')
        ? _baseUrl.substring(0, _baseUrl.length - 1)
        : _baseUrl;
    final uri = Uri.parse('$base$exchangePath');

    http.Response response;
    try {
      // Both fields are required by the server. Sent as a form body, never as
      // a query string: the endpoint reads them with r.PostFormValue.
      final request = http.Request('POST', uri)
        ..bodyFields = {'code': code, 'redirect_uri': redirectUri};
      response = await http.Response.fromStream(await _http.send(request));
    } on http.ClientException catch (e, stack) {
      throw NetworkError(
        'Could not reach the social-login exchange endpoint: ${e.message}',
        cause: stack,
      );
    } on SocketException catch (e, stack) {
      throw NetworkError(
        'Could not reach the social-login exchange endpoint: ${e.message}',
        cause: stack,
      );
    }

    if (response.statusCode != 200) {
      // the spec makes expired / replayed / wrong-audience / unknown deliberately
      // indistinguishable (400 "invalid request") so the endpoint is not an
      // oracle. 405 means the request was not a POST.
      throw AuthError(
        'Social login code exchange was refused '
        '(HTTP ${response.statusCode}). The code is single-use and expires in '
        '60 seconds; it is also bound to the exact redirect_uri it was issued '
        'for. Start the login again.',
      );
    }

    Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(response.body);
      if (parsed is! Map<String, dynamic>) {
        throw const FormatException('exchange response was not a JSON object');
      }
      decoded = parsed;
    } on FormatException catch (e, stack) {
      throw AuthError(
        'Social login code exchange returned a malformed body: ${e.message}',
        cause: stack,
      );
    }

    final access = decoded['access_token'];
    final refresh = decoded['refresh_token'];
    if (access is! String ||
        access.isEmpty ||
        refresh is! String ||
        refresh.isEmpty) {
      throw AuthError(
        'Social login code exchange returned no usable token pair. Refusing to '
        'build a half-authenticated session.',
      );
    }

    // Consumer social login is user-scoped, so the session carries an empty
    // companyId / role and a minimal placeholder user (the real profile is
    // hydrated from the JWT and subsequent API calls).
    return PlatformSession(
      accessToken: access,
      refreshToken: refresh,
      user: const PlatformUser(
        id: '',
        email: '',
        displayName: '',
        isActive: true,
      ),
      companyId: '',
      role: '',
    );
  }
}
