// R-ACL-03 AoidOidcAuthStrategy — client-side OAuth 2.0 authorization-code
// + PKCE (S256) login against AOID.
//
// Public client (token_endpoint_auth_method=none): the SPA bundle holds NO
// client secret. Login drives {issuer}/oauth/authorize through an injectable
// browser-launch fn (default FlutterWebAuth2.authenticate), verifies the
// returned CSRF `state`, exchanges the code at {issuer}/oauth/token, and
// builds a BEARER PlatformSession. restoreSession() runs the AOID
// refresh_token grant; logout() best-effort POSTs {issuer}/oauth/revoke.
//
// Promoted from eden-biz-console-login/flutter (AOID-CONSOLE-LOGIN-03-TRD)
// into this shared package so console/mobile/POS all consume one
// implementation. See docs/aoid-console-oauth-client.md in that repo for the
// frozen contract this strategy implements.
//
// Lives on the ADAPTER side of the riverpod split (AOID obj-50 TRD 50-01)
// because it `implements AuthStrategy`, the interface AuthNotifier — a
// riverpod-2 StateNotifier — drives. Reachable via
// `package:eden_platform_flutter/aoid_riverpod.dart`, never from aoid.dart.
// (Its own import closure happens to be riverpod-free today; the placement is
// a layering decision about where AuthStrategy belongs, not a present
// technical necessity. 50-04 owns auth_strategy.dart.)

import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

import '../aoid/pkce.dart';
import '../auth/auth_strategy.dart';
import '../auth/token_storage.dart';
import '../models/platform_models.dart';

/// Injectable browser-launch signature. Matches the callable shape of
/// [FlutterWebAuth2.authenticate] (its extra optional `options` param is
/// assignable to this narrower type).
typedef AuthorizeFn = Future<String> Function({
  required String url,
  required String callbackUrlScheme,
});

/// AOID authorization-code + PKCE(S256) [AuthStrategy].
class AoidOidcAuthStrategy implements AuthStrategy {
  AoidOidcAuthStrategy({
    required this.tokenStorage,
    required this.issuer,
    required this.clientId,
    required this.redirectUri,
    http.Client? httpClient,
    AuthorizeFn? authorize,
  })  : _httpClient = httpClient ?? http.Client(),
        _authorize = authorize ?? FlutterWebAuth2.authenticate;

  final TokenStorage tokenStorage;

  /// AOID issuer origin, e.g. `https://auth.aocyber.ai`. Endpoints are
  /// `{issuer}/oauth/authorize`, `/oauth/token`, `/oauth/revoke`.
  final String issuer;

  /// Public OAuth client id, e.g. `eden-biz-console`.
  final String clientId;

  /// Registered redirect_uri, e.g. `.../auth.html`.
  final String redirectUri;

  final http.Client _httpClient;
  final AuthorizeFn _authorize;

  /// PKCE material for the in-flight authorization request. Held between the
  /// authorize launch and the token exchange, and cleared by [logout] (AOID
  /// frozen contract: no PKCE material should outlive a logout).
  PkcePair? _pendingPkce;

  /// OIDC scopes requested at authorize + the offline_access needed to be
  /// issued a refresh token.
  static const String _scope = 'openid profile email offline_access';

  // Canonical [Failed] reasons — consolidated so callers/logs see stable,
  // greppable strings.
  static const String _reasonStateMismatch = 'AOID state mismatch';
  static const String _reasonNoCode = 'AOID authorization returned no code';
  static const String _reasonBadTokenJson =
      'AOID token response was not valid JSON';
  static const String _reasonMissingTokens =
      'AOID token response missing access/refresh token';
  static const String _reasonCompleteUnsupported =
      'AOID authorization-code flow does not support completeLogin '
      '(not supported)';

  Uri get _authorizeEndpoint => Uri.parse('$issuer/oauth/authorize');
  Uri get _tokenEndpoint => Uri.parse('$issuer/oauth/token');
  Uri get _revokeEndpoint => Uri.parse('$issuer/oauth/revoke');

  /// Placeholder end-user identity. AOID's authoritative profile is fetched
  /// downstream (WhoAmI / entitlements); the session only needs a non-null
  /// PlatformUser to satisfy the bearer contract here.
  static const PlatformUser _placeholderUser = PlatformUser(
    id: '',
    email: '',
    displayName: '',
    avatarUrl: '',
    isActive: true,
  );

  /// callbackUrlScheme for the browser-launch: `https` on web (universal-link
  /// style, served by web/auth.html), custom `edenbiz` scheme on native.
  String get _callbackUrlScheme => kIsWeb ? 'https' : 'edenbiz';

  /// Builds the AOID `/oauth/authorize` URL (frozen contract §1) for the
  /// given PKCE material.
  Uri _buildAuthorizeUrl(PkcePair pair) =>
      _authorizeEndpoint.replace(queryParameters: {
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'scope': _scope,
        'code_challenge': pair.codeChallenge,
        'code_challenge_method': 'S256',
        'state': pair.state,
      });

  @override
  Future<AuthResult> initiateLogin(Map<String, String> credentials) async {
    // Fresh PKCE material held on the instance for the duration of the
    // in-flight request; cleared on every completion path (and by logout).
    final pair = PkceGenerator.generate();
    _pendingPkce = pair;
    try {
      final authorizeUrl = _buildAuthorizeUrl(pair);

      final String callback;
      try {
        callback = await _authorize(
          url: authorizeUrl.toString(),
          callbackUrlScheme: _callbackUrlScheme,
        );
      } catch (e) {
        return Failed('AOID authorization failed: $e');
      }

      final params = Uri.parse(callback).queryParameters;
      final code = params['code'];
      final returnedState = params['state'];

      // CSRF guard: verify the echoed state against the in-flight PKCE
      // state BEFORE any token exchange.
      if (returnedState != _pendingPkce!.state) {
        return const Failed(_reasonStateMismatch);
      }
      if (code == null || code.isEmpty) {
        return const Failed(_reasonNoCode);
      }

      return _exchangeCode(
        code: code,
        codeVerifier: _pendingPkce!.codeVerifier,
      );
    } finally {
      // PKCE material must not outlive the request.
      _pendingPkce = null;
    }
  }

  /// Exchange an authorization code at {issuer}/oauth/token (public client,
  /// NO client_secret) and build a BEARER PlatformSession.
  Future<AuthResult> _exchangeCode({
    required String code,
    required String codeVerifier,
  }) async {
    final http.Response resp;
    try {
      resp = await _httpClient.post(_tokenEndpoint, body: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri,
        'client_id': clientId,
        'code_verifier': codeVerifier,
      });
    } catch (e) {
      return Failed('AOID token exchange failed: $e');
    }

    if (resp.statusCode != 200) {
      return Failed('AOID token exchange rejected (${resp.statusCode})');
    }

    return _sessionFromTokenResponse(resp.body);
  }

  /// Parse a token-endpoint JSON body and persist + wrap it as a BEARER
  /// PlatformSession (companyId/role null, placeholder user).
  Future<AuthResult> _sessionFromTokenResponse(String body) async {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      return Failed('$_reasonBadTokenJson: $e');
    }

    final accessToken = json['access_token'] as String?;
    final refreshToken = json['refresh_token'] as String?;
    // AOID returns the OIDC id_token (verified email/email_verified) here; it
    // was previously discarded. Capture it — biz-api's JIT path keys off the
    // verified email (COMPANION-AV05-AOID-JIT). Optional: null when absent
    // (legacy/non-OIDC responses) so the session stays backward-compatible.
    final idToken = json['id_token'] as String?;
    if (accessToken == null || refreshToken == null) {
      return const Failed(_reasonMissingTokens);
    }

    await tokenStorage.writeAccessToken(accessToken);
    await tokenStorage.writeRefreshToken(refreshToken);

    return Authenticated(PlatformSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      user: _placeholderUser,
      companyId: null,
      role: null,
      idToken: idToken,
    ));
  }

  @override
  Future<AuthResult> completeLogin(
    String continuationToken,
    Map<String, String> proof,
  ) async =>
      const Failed(_reasonCompleteUnsupported);

  @override
  Future<void> logout() async {
    // Best-effort server-side revoke — must NEVER throw on network/server
    // errors (AuthStrategy contract). Public client: token + client_id, no
    // secret.
    final refreshToken = await tokenStorage.readRefreshToken();
    if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        await _httpClient.post(_revokeEndpoint, body: {
          'token': refreshToken,
          'client_id': clientId,
        });
      } catch (_) {
        // Swallow — revoke is best-effort.
      }
    }

    // Always clear local state (tokens + any pending PKCE) regardless of the
    // revoke outcome.
    _pendingPkce = null;
    await tokenStorage.clear();
  }

  @override
  Future<PlatformSession?> restoreSession() async {
    final refreshToken = await tokenStorage.readRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      return null;
    }

    final http.Response resp;
    try {
      resp = await _httpClient.post(_tokenEndpoint, body: {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId,
      });
    } catch (_) {
      // Transient network error — let the UI re-prompt for login.
      return null;
    }

    if (resp.statusCode != 200) {
      return null;
    }

    final result = await _sessionFromTokenResponse(resp.body);
    return result is Authenticated ? result.session : null;
  }
}
