import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../api/platform_repository.dart';
import '../models/platform_models.dart';

/// Drives the consumer social-login OAuth flow using
/// [flutter_web_auth_2], which presents the provider's authorization page in
/// an `ASWebAuthenticationSession` (iOS/macOS), Chrome Custom Tab (Android),
/// or a `postMessage`-backed popup (Web).
///
/// Unlike the enterprise [SSOAuthService] (desktop-only localhost server, web
/// unsupported), this service works uniformly on web + mobile. The backend
/// initiates the flow (`InitiateSocialLogin` RPC) and, after the provider
/// callback, delivers the ML-DSA-65 token pair back to the app by redirecting
/// to the configured `redirect_uri` with `access_token` + `refresh_token`
/// query parameters. This service parses those tokens into a
/// [PlatformSession]; the caller persists them via the standard
/// `AuthNotifier._persistTokens` (SecureTokenStorage) path.
class SocialAuthService {
  SocialAuthService({
    required PlatformRepository repository,
    required String baseUrl,
  })  : _repository = repository,
        _baseUrl = baseUrl;

  final PlatformRepository _repository;
  // Retained for parity with [SSOAuthService] and future per-instance use
  // (e.g. constructing absolute callback URLs); the server already knows its
  // own base URL, so the value is not currently sent on the wire.
  // ignore: unused_field
  final String _baseUrl;

  /// Custom URL scheme registered in the native shells (iOS Info.plist
  /// CFBundleURLSchemes, Android AndroidManifest intent-filter). Web ignores
  /// this and uses the `auth.html` postMessage target instead.
  static const String mobileCallbackScheme = 'com.justindonnaruma.app';

  /// Initiates social login for [provider] (`google` | `apple` | `microsoft`
  /// | `facebook` | `x`) and returns the resulting [PlatformSession].
  ///
  /// Flow: ask the backend for the provider authorization URL → open the
  /// browser session → parse the token pair the server appended to the
  /// callback URL.
  Future<PlatformSession> authenticate(String provider) async {
    final redirectUri = _buildRedirectUri();

    final authUrl = await _repository.initiateSocialLogin(provider, redirectUri);

    final callbackUrl = await FlutterWebAuth2.authenticate(
      url: authUrl,
      // Web uses the `auth.html` postMessage target (scheme is `https`);
      // mobile rejoins the app via the custom scheme.
      callbackUrlScheme: kIsWeb ? 'https' : mobileCallbackScheme,
    );

    return sessionFromCallbackUrl(callbackUrl);
  }

  /// Resolve the redirect URI the server should send the user back to.
  /// Delegated to the pure [redirectUriFor] so it stays unit-testable without
  /// touching `Uri.base` / `kIsWeb` at call sites.
  String _buildRedirectUri() => redirectUriFor(
        isWeb: kIsWeb,
        webOrigin: Uri.base.origin,
      );

  /// Pure helper: build the platform-appropriate OAuth redirect URI.
  ///
  /// - Web: `${origin}/auth.html` — the postMessage callback page that
  ///   flutter_web_auth_2 reads on the web platform.
  /// - Mobile/desktop: the `com.justindonnaruma.app://auth/social/callback`
  ///   deep link.
  static String redirectUriFor({
    required bool isWeb,
    required String webOrigin,
  }) {
    if (isWeb) {
      return '$webOrigin/auth.html';
    }
    return '$mobileCallbackScheme://auth/social/callback';
  }

  /// Pure helper: parse the server's callback URL into a [PlatformSession].
  ///
  /// The server appends `access_token` + `refresh_token` query parameters on
  /// success, or an `error` parameter on failure. Consumer social login is
  /// user-scoped, so the session carries an empty `companyId` / `role` and a
  /// minimal placeholder user (the real profile is hydrated from the JWT /
  /// subsequent API calls).
  static PlatformSession sessionFromCallbackUrl(String callbackUrl) {
    final uri = Uri.parse(callbackUrl);
    final params = uri.queryParameters;

    final error = params['error'];
    if (error != null && error.isNotEmpty) {
      throw Exception('Social login failed: $error');
    }

    final accessToken = params['access_token'];
    final refreshToken = params['refresh_token'];
    if (accessToken == null ||
        accessToken.isEmpty ||
        refreshToken == null ||
        refreshToken.isEmpty) {
      throw Exception('Social login callback missing tokens');
    }

    return PlatformSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
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
