import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:eden_platform_flutter/src/errors/platform_errors.dart';

/// Shared fake implementation of [PlatformRepository] for unit tests.
///
/// Configure results and errors before each test. Counters track call counts.
class FakePlatformRepository implements PlatformRepository {
  // Configurable results
  PlatformSession? loginResult;
  PlatformSession? signUpResult;
  PlatformSession? refreshResult;
  List<PlatformCompany>? listCompaniesResult;
  List<PlatformNavItem>? listNavItemsResult;

  // Configurable errors (thrown if set, checked before result)
  Object? loginError;
  Object? signUpError;
  Object? refreshError;
  Object? listCompaniesError;
  Object? listNavItemsError;

  // Call counters
  int loginCalls = 0;
  int signUpCalls = 0;
  int refreshCalls = 0;
  int logoutCalls = 0;
  int listCompaniesCalls = 0;
  int listNavItemsCalls = 0;

  @override
  Future<PlatformSession> login(String email, String password) async {
    loginCalls++;
    if (loginError != null) throw loginError!;
    return loginResult!;
  }

  @override
  Future<PlatformSession> signUp(
      String email, String password, String displayName) async {
    signUpCalls++;
    if (signUpError != null) throw signUpError!;
    return signUpResult ?? loginResult!;
  }

  @override
  Future<PlatformSession> refreshToken(String refreshToken) async {
    refreshCalls++;
    if (refreshError != null) throw refreshError!;
    if (refreshResult == null) {
      throw StateError('missing refresh result');
    }
    return refreshResult!;
  }

  @override
  Future<void> logout(String refreshToken) async {
    logoutCalls++;
  }

  @override
  Future<List<PlatformCompany>> listCompanies(String accessToken) async {
    listCompaniesCalls++;
    if (listCompaniesError != null) throw listCompaniesError!;
    return listCompaniesResult ?? const [];
  }

  @override
  Future<List<PlatformNavItem>> listNavItems(
      String accessToken, String companyId) async {
    listNavItemsCalls++;
    if (listNavItemsError != null) throw listNavItemsError!;
    return listNavItemsResult ?? const [];
  }
}

/// Waits for microtasks and short timers to complete.
Future<void> settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

/// Creates a [PlatformSession] with sensible defaults.
PlatformSession buildSession({
  String accessToken = 'access-token',
  String refreshToken = 'refresh-token',
  String userId = 'user-1',
  String email = 'dev@example.com',
  String displayName = 'Dev User',
  String? companyId = 'company-1',
  String? role = 'owner',
}) {
  return PlatformSession(
    accessToken: accessToken,
    refreshToken: refreshToken,
    companyId: companyId,
    role: role,
    user: PlatformUser(
      id: userId,
      email: email,
      displayName: displayName,
      isActive: true,
    ),
  );
}

/// Creates a [PlatformCompany] with sensible defaults.
PlatformCompany buildCompany({
  String id = 'company-1',
  String name = 'Test Company',
  String slug = 'test-company',
  String companyType = 'standard',
}) {
  return PlatformCompany(
    id: id,
    name: name,
    slug: slug,
    companyType: companyType,
  );
}

/// Creates a [PlatformNavItem] with sensible defaults.
PlatformNavItem buildNavItem({
  String id = 'nav-1',
  String label = 'Home',
  String icon = 'home',
  String path = '/home',
  String feature = 'home',
  int priority = 0,
  int badgeCount = 0,
}) {
  return PlatformNavItem(
    id: id,
    label: label,
    icon: icon,
    path: path,
    feature: feature,
    priority: priority,
    badgeCount: badgeCount,
  );
}
