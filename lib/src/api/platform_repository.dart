import 'dart:convert';
import 'dart:developer';

import 'package:connectrpc/connect.dart';
import 'package:eden_platform_api_dart/eden_platform_api_dart.dart';

import '../errors/platform_errors.dart';
import '../models/platform_models.dart';

abstract class PlatformRepository {
  Future<PlatformSession> login(String email, String password);
  Future<PlatformSession> signUp(String email, String password, String displayName);
  Future<PlatformSession> refreshToken(String refreshToken);
  Future<void> logout(String refreshToken);
  Future<List<PlatformCompany>> listCompanies(String accessToken);
  Future<List<PlatformNavItem>> listNavItems(String accessToken, String companyId);
}

class ConnectPlatformRepository implements PlatformRepository {
  ConnectPlatformRepository({required String baseUrl})
      : _transport = createPlatformTransport(baseUrl: baseUrl);

  final Transport _transport;

  Headers _authHeaders(String accessToken) {
    final headers = Headers();
    headers['Authorization'] = 'Bearer $accessToken';
    return headers;
  }

  @override
  Future<PlatformSession> login(String email, String password) async {
    try {
      final response = await AuthServiceClient(_transport).login(
        LoginRequest()
          ..email = email
          ..password = password,
      );
      return _sessionFromAuthResponse(response);
    } catch (e, stack) {
      throw _wrapConnectError(e, stack);
    }
  }

  @override
  Future<PlatformSession> signUp(String email, String password, String displayName) async {
    try {
      final response = await AuthServiceClient(_transport).signUp(
        SignUpRequest()
          ..email = email
          ..password = password
          ..displayName = displayName,
      );
      return _sessionFromAuthResponse(response);
    } catch (e, stack) {
      throw _wrapConnectError(e, stack);
    }
  }

  @override
  Future<PlatformSession> refreshToken(String refreshToken) async {
    try {
      final response = await AuthServiceClient(_transport).refreshToken(
        RefreshTokenRequest()..refreshToken = refreshToken,
      );
      return _sessionFromAuthResponse(response);
    } catch (e, stack) {
      throw _wrapConnectError(e, stack);
    }
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
              badgeCount: badgeResponse.counts[item.id] ?? 0,
            ),
          )
          .toList(growable: false)
        ..sort((a, b) => a.priority.compareTo(b.priority));
    } catch (e, stack) {
      throw _wrapConnectError(e, stack);
    }
  }

  PlatformSession _sessionFromAuthResponse(AuthResponse response) {
    final claims = _extractClaims(response.accessToken);
    final user = response.user;
    return PlatformSession(
      accessToken: response.accessToken,
      refreshToken: response.refreshToken,
      user: PlatformUser(
        id: user.id,
        email: user.email,
        displayName: user.displayName,
        isActive: user.isActive,
        createdAt: DateTime.tryParse(user.createdAt),
      ),
      companyId: claims['cid'],
      role: claims['role'],
    );
  }

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
