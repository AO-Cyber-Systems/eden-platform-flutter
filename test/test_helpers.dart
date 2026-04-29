import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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

  // Pre-existing methods on PlatformRepository that older test_helpers.dart
  // missed (added by TRD 10-03 for cross-repo unblocking — see SUMMARY).
  // Both throw UnimplementedError; tests that exercise these paths must
  // configure a result/error explicitly via subclass.
  @override
  Future<String> initiateSSOForDesktop(String provider, String redirectUri) async {
    throw UnimplementedError('configure FakePlatformRepository subclass for SSO');
  }

  @override
  Future<PlatformUser> updateProfile(
      String accessToken, String displayName, String avatarUrl) async {
    throw UnimplementedError('configure FakePlatformRepository subclass for profile updates');
  }
}

/// Waits for microtasks and short timers to complete.
Future<void> settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

/// Installs an in-memory mock for the `flutter_secure_storage` MethodChannel
/// so tests that exercise the default `SecureTokenStorage` (via
/// `tokenStorageProvider`) don't hit MissingPluginException.
///
/// Tests that prefer to inject a fake TokenStorage via
/// `tokenStorageProvider.overrideWithValue(FakeTokenStorage())` can skip this
/// helper. The existing `auth_provider_test.dart` predates the TokenStorage
/// abstraction and uses [installSecureStorageChannelMock] for backward
/// compatibility — it asserts SharedPreferences state, but with the storage
/// swap those assertions are replaced by reads from the in-memory secure-store
/// map.
///
/// Returns a Map you can read/write to assert the stored values directly.
/// Reset the map per-test via setUp() if you need isolated state.
const _secureChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

Map<String, String> installSecureStorageChannelMock() {
  final store = <String, String>{};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureChannel, (MethodCall call) async {
    switch (call.method) {
      case 'read':
        final key = (call.arguments as Map)['key'] as String;
        return store[key];
      case 'write':
        final key = (call.arguments as Map)['key'] as String;
        final value = (call.arguments as Map)['value'] as String;
        store[key] = value;
        return null;
      case 'delete':
        final key = (call.arguments as Map)['key'] as String;
        store.remove(key);
        return null;
      case 'deleteAll':
        store.clear();
        return null;
      case 'readAll':
        return Map<String, String>.from(store);
      case 'containsKey':
        final key = (call.arguments as Map)['key'] as String;
        return store.containsKey(key);
    }
    return null;
  });
  return store;
}

void uninstallSecureStorageChannelMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureChannel, null);
}

/// In-memory [TokenStorage] for tests that pass an explicit storage instead
/// of relying on the channel mock. Useful when a test needs to construct
/// AuthNotifier directly (rather than via tokenStorageProvider).
class FakeTokenStorage implements TokenStorage {
  final Map<String, String?> _values = <String, String?>{};
  int readAccessCalls = 0;
  int readRefreshCalls = 0;
  int writeAccessCalls = 0;
  int writeRefreshCalls = 0;
  int clearCalls = 0;

  @override
  Future<String?> readAccessToken() async {
    readAccessCalls++;
    return _values['access'];
  }

  @override
  Future<String?> readRefreshToken() async {
    readRefreshCalls++;
    return _values['refresh'];
  }

  @override
  Future<void> writeAccessToken(String? value) async {
    writeAccessCalls++;
    _values['access'] = value;
  }

  @override
  Future<void> writeRefreshToken(String? value) async {
    writeRefreshCalls++;
    _values['refresh'] = value;
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    _values.clear();
  }

  void seed({String? access, String? refresh}) {
    if (access != null) _values['access'] = access;
    if (refresh != null) _values['refresh'] = refresh;
  }
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
