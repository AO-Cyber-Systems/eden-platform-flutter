import 'dart:convert';

import 'package:connectrpc/connect.dart';
import 'package:eden_platform_api_dart/eden_platform_api_dart.dart';

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
    final response = await AuthServiceClient(_transport).login(
      LoginRequest()
        ..email = email
        ..password = password,
    );
    return _sessionFromAuthResponse(response);
  }

  @override
  Future<PlatformSession> signUp(String email, String password, String displayName) async {
    final response = await AuthServiceClient(_transport).signUp(
      SignUpRequest()
        ..email = email
        ..password = password
        ..displayName = displayName,
    );
    return _sessionFromAuthResponse(response);
  }

  @override
  Future<PlatformSession> refreshToken(String refreshToken) async {
    final response = await AuthServiceClient(_transport).refreshToken(
      RefreshTokenRequest()..refreshToken = refreshToken,
    );
    return _sessionFromAuthResponse(response);
  }

  @override
  Future<void> logout(String refreshToken) async {
    await AuthServiceClient(_transport).logout(
      LogoutRequest()..refreshToken = refreshToken,
    );
  }

  @override
  Future<List<PlatformCompany>> listCompanies(String accessToken) async {
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
  }

  @override
  Future<List<PlatformNavItem>> listNavItems(String accessToken, String companyId) async {
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
    } catch (_) {
      return const {};
    }
  }
}
