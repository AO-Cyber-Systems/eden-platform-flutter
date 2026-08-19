import 'dart:convert';
import 'dart:developer';

import 'package:connectrpc/connect.dart';
import 'package:eden_platform_api_dart/eden_platform_api_dart.dart';
import 'package:http/http.dart' as http;

import '../errors/platform_errors.dart';
import '../models/platform_models.dart';

abstract class PlatformRepository {
  Future<PlatformSession> login(String email, String password);
  Future<PlatformSession> signUp(String email, String password, String displayName);
  Future<PlatformSession> refreshToken(String refreshToken);
  Future<void> logout(String refreshToken);
  Future<List<PlatformCompany>> listCompanies(String accessToken);
  Future<List<PlatformNavItem>> listNavItems(String accessToken, String companyId);

  /// Returns the enterprise SSO authorization URL for a desktop loopback flow.
  ///
  /// DEPRECATED. Its only consumer
  /// was `SSOAuthService`, which has been DELETED: it read `access_token` and
  /// `refresh_token` out of the loopback callback URL and launched the browser
  /// through `Process.run`. Nothing in eden calls this method any more.
  ///
  /// It is kept — deprecated rather than removed — because 6 `@override`
  /// implementations of it exist in test fakes across 5 consumer packages
  /// (politihub/flutter-navigators, justinforme/flutter/{admin,volunteer},
  /// eden-biz/{flutter,mobile}), four of which consume this package by PATH and
  /// would take a new `override_on_non_overriding_member` analyzer warning the
  /// moment it disappeared. Removing it is a coordinated cross-repo change, not
  /// a side effect of a security fix.
  ///
  /// Deprecating costs those consumers nothing: an `@override` of a deprecated
  /// member produces no diagnostic (verified with `dart analyze`).
  ///
  /// Use `initiateSocialLogin` + [SocialAuthService], which is cross-platform
  /// and takes an authorization CODE rather than tokens in a URL.
  @Deprecated(
    'Unused since the spec removed SSOAuthService (a tokens-in-URL loopback '
    'reader that shelled out to launch a browser). '
    'Use initiateSocialLogin + SocialAuthService. Slated for removal in a '
    'coordinated cross-repo change once consumer test fakes drop their overrides.',
  )
  Future<String> initiateSSOForDesktop(String provider, String redirectUri);

  /// Starts a consumer social-login flow (Google, Apple, Microsoft, Facebook,
  /// X). Returns the provider authorization URL the client must open. Tokens
  /// are delivered out-of-band by the server's `/auth/social/callback` HTTP
  /// handler via redirect — not in this response.
  Future<String> initiateSocialLogin(String provider, String redirectUri);

  Future<PlatformUser> updateProfile(String accessToken, String displayName, String avatarUrl);
}

class ConnectPlatformRepository implements PlatformRepository {
  ConnectPlatformRepository({required String baseUrl})
      : _baseUrl = baseUrl,
        _transport = createPlatformTransport(baseUrl: baseUrl);

  final String _baseUrl;
  final Transport _transport;

  Headers _authHeaders(String accessToken) {
    final headers = Headers();
    headers['Authorization'] = 'Bearer $accessToken';
    return headers;
  }

  // Login / SignUp / RefreshToken use raw HTTP+JSON instead of the generated
  // ConnectRPC client because the Dart proto has been regenerated to nest auth
  // fields under `LoginResponse.auth: AuthData`, while the currently-deployed
  // platform servers still emit the older flat `AuthResponse` shape (fields:
  // accessToken / refreshToken / user at the top level). Until eden-platform-go
  // catches up, parsing the wire response through the generated proto would
  // silently produce empty tokens. See
  // https://github.com/AO-Cyber-Systems/eden-platform-go/issues/20 for the
  // households-table conflict that is currently blocking the proto bump.
  @override
  Future<PlatformSession> login(String email, String password) async {
    return _authPost(
      method: 'Login',
      body: {'email': email, 'password': password},
    );
  }

  @override
  Future<PlatformSession> signUp(String email, String password, String displayName) async {
    return _authPost(
      method: 'SignUp',
      body: {
        'email': email,
        'password': password,
        'displayName': displayName,
      },
    );
  }

  @override
  Future<PlatformSession> refreshToken(String refreshToken) async {
    return _authPost(
      method: 'RefreshToken',
      body: {'refreshToken': refreshToken},
    );
  }

  Future<PlatformSession> _authPost({
    required String method,
    required Map<String, dynamic> body,
  }) async {
    final url = Uri.parse('$_baseUrl/platform.v1.AuthService/$method');
    try {
      final resp = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      if (resp.statusCode != 200) {
        throw AuthError(
          'Auth $method failed (HTTP ${resp.statusCode}): ${resp.body}',
        );
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      // Support both shapes:
      //   1. Flat (current server):  {accessToken, refreshToken, user}
      //   2. Nested (future server): {auth: {accessToken, refreshToken, user}}
      final root = data['auth'] is Map ? data['auth'] as Map<String, dynamic> : data;
      return _sessionFromJsonMap(root);
    } catch (e, stack) {
      if (e is PlatformError) rethrow;
      log('Auth $method failed: $e', name: 'ConnectPlatformRepository', stackTrace: stack);
      throw NetworkError('Auth $method transport failure: $e', cause: e);
    }
  }

  PlatformSession _sessionFromJsonMap(Map<String, dynamic> m) {
    final accessToken = (m['accessToken'] as String?) ?? '';
    final refreshTokenStr = (m['refreshToken'] as String?) ?? '';
    final user = (m['user'] as Map<String, dynamic>?) ?? const {};
    final claims = _extractClaims(accessToken);
    return PlatformSession(
      accessToken: accessToken,
      refreshToken: refreshTokenStr,
      user: PlatformUser(
        id: (user['id'] as String?) ?? '',
        email: (user['email'] as String?) ?? '',
        displayName: (user['displayName'] as String?) ?? '',
        avatarUrl: (user['avatarUrl'] as String?) ?? '',
        isActive: (user['isActive'] as bool?) ?? true,
        createdAt: DateTime.tryParse((user['createdAt'] as String?) ?? ''),
      ),
      companyId: claims['cid'],
      role: claims['role'],
    );
  }

  @override
  Future<void> logout(String refreshToken) async {
    try {
      await AuthServiceClient(_transport).logout(
        LogoutRequest()..refreshToken = refreshToken,
      );
    } catch (e, stack) {
      throw _wrapConnectError(e, stack);
    }
  }

  @override
  Future<List<PlatformCompany>> listCompanies(String accessToken) async {
    try {
      final response = await CompanyServiceClient(_transport).listCompanies(
        ListCompaniesRequest(),
        headers: _authHeaders(accessToken),
      );

      return response.companies
          .map(
            (company) => PlatformCompany(
              id: company.id,
              name: company.name,
              slug: company.slug,
              companyType: company.companyType,
            ),
          )
          .toList(growable: false);
    } catch (e, stack) {
      throw _wrapConnectError(e, stack);
    }
  }

  @override
  Future<List<PlatformNavItem>> listNavItems(String accessToken, String companyId) async {
    try {
      final headers = _authHeaders(accessToken);
      final navResponse = await RegistryServiceClient(_transport).getNavItems(
        GetNavItemsRequest()..companyId = companyId,
        headers: headers,
      );
      final badgeResponse = await RegistryServiceClient(_transport).getBadgeCounts(
        GetBadgeCountsRequest()..companyId = companyId,
        headers: headers,
      );

      return navResponse.items
          .map(
            (item) => PlatformNavItem(
              id: item.id,
              label: item.label,
              icon: item.icon,
              path: item.path,
              feature: item.feature,
              priority: item.priority,
              section: item.section,
              badgeCount: badgeResponse.counts[item.id] ?? 0,
            ),
          )
          .toList(growable: false)
        ..sort((a, b) => a.priority.compareTo(b.priority));
    } catch (e, stack) {
      throw _wrapConnectError(e, stack);
    }
  }

  @override
  Future<String> initiateSSOForDesktop(String provider, String redirectUri) async {
    // Direct HTTP call since the proto doesn't have provider/redirectUri fields yet.
    // The backend returns { "auth_url": "...", "state": "..." }.
    try {
      final response = await AuthServiceClient(_transport).initiateOIDC(
        InitiateOIDCRequest()..companyId = '', // Will be resolved server-side
      );
      return response.authUrl;
    } catch (e, stack) {
      throw _wrapConnectError(e, stack);
    }
  }

  @override
  Future<String> initiateSocialLogin(String provider, String redirectUri) async {
    try {
      final response = await AuthServiceClient(_transport).initiateSocialLogin(
        InitiateSocialLoginRequest()
          ..provider = provider
          ..redirectUri = redirectUri,
      );
      return response.authUrl;
    } catch (e, stack) {
      throw _wrapConnectError(e, stack);
    }
  }

  @override
  Future<PlatformUser> updateProfile(String accessToken, String displayName, String avatarUrl) async {
    try {
      final response = await AuthServiceClient(_transport).updateProfile(
        UpdateProfileRequest()
          ..displayName = displayName
          ..avatarUrl = avatarUrl,
        headers: _authHeaders(accessToken),
      );
      final user = response.user;
      return PlatformUser(
        id: user.id,
        email: user.email,
        displayName: user.displayName,
        avatarUrl: user.avatarUrl,
        isActive: user.isActive,
        createdAt: DateTime.tryParse(user.createdAt),
      );
    } catch (e, stack) {
      throw _wrapConnectError(e, stack);
    }
  }

  // _sessionFromAuthData removed: the auth endpoints now use raw HTTP+JSON via
  // _authPost / _sessionFromJsonMap, so the proto-typed helper is no longer
  // needed. When eden-platform-go ships a vendor with the nested AuthData
  // wire format and downstream apps adopt it, restore this helper and switch
  // back to the generated ConnectRPC client. Until then the JSON path supports
  // both flat (current) and nested (future) server shapes.

  Map<String, String> _extractClaims(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) {
        return const {};
      }
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final raw = jsonDecode(payload) as Map<String, dynamic>;
      return raw.map((key, value) => MapEntry(key, value.toString()));
    } catch (e) {
      log('JWT claim extraction failed: $e', name: 'ConnectPlatformRepository');
      return const {};
    }
  }

  Never _wrapConnectError(Object error, StackTrace stack) {
    if (error is PlatformError) {
      throw error;
    }
    if (error is ConnectException) {
      switch (error.code) {
        case Code.unauthenticated:
        case Code.permissionDenied:
          throw AuthError(error.message, cause: error);
        case Code.unavailable:
        case Code.deadlineExceeded:
          throw NetworkError(error.message, cause: error);
        default:
          throw ServerError(error.message, code: error.code.value, cause: error);
      }
    }
    throw ServerError('Unexpected error', cause: error);
  }
}
