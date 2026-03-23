import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePlatformRepository implements PlatformRepository {
  PlatformSession? loginResult;
  PlatformSession? refreshResult;
  int refreshCalls = 0;
  int logoutCalls = 0;

  @override
  Future<List<PlatformCompany>> listCompanies(String accessToken) async => const [];

  @override
  Future<List<PlatformNavItem>> listNavItems(String accessToken, String companyId) async => const [];

  @override
  Future<PlatformSession> login(String email, String password) async {
    return loginResult!;
  }

  @override
  Future<void> logout(String refreshToken) async {
    logoutCalls += 1;
  }

  @override
  Future<PlatformSession> refreshToken(String refreshToken) async {
    refreshCalls += 1;
    if (refreshResult == null) {
      throw StateError('missing refresh result');
    }
    return refreshResult!;
  }

  @override
  Future<PlatformSession> signUp(String email, String password, String displayName) async {
    return loginResult!;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PlatformSession buildSession() {
    return PlatformSession(
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      companyId: 'company-1',
      role: 'owner',
      user: const PlatformUser(
        id: 'user-1',
        email: 'dev@example.com',
        displayName: 'Dev User',
        isActive: true,
      ),
    );
  }

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  test('restoreSession without persisted tokens becomes unauthenticated', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = _FakePlatformRepository();
    final container = ProviderContainer(
      overrides: [platformRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    container.read(authProvider.notifier);
    await settle();

    final state = container.read(authProvider);
    expect(state.status, AuthStatus.unauthenticated);
    expect(state.isAuthenticated, false);
    expect(repository.refreshCalls, 0);
  });

  test('login stores an authenticated session', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = _FakePlatformRepository()..loginResult = buildSession();
    final container = ProviderContainer(
      overrides: [platformRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    final notifier = container.read(authProvider.notifier);
    await settle();
    await notifier.login('dev@example.com', 'password123');

    final state = container.read(authProvider);
    expect(state.status, AuthStatus.authenticated);
    expect(state.isAuthenticated, true);
    expect(state.userId, 'user-1');
    expect(state.companyId, 'company-1');
    expect(state.role, 'owner');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('access_token'), 'access-token');
    expect(prefs.getString('refresh_token'), 'refresh-token');
  });

  test('restoreSession refreshes persisted tokens', () async {
    SharedPreferences.setMockInitialValues({
      'refresh_token': 'existing-refresh',
    });
    final repository = _FakePlatformRepository()..refreshResult = buildSession();
    final container = ProviderContainer(
      overrides: [platformRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    container.read(authProvider.notifier);
    await settle();

    final state = container.read(authProvider);
    expect(repository.refreshCalls, 1);
    expect(state.status, AuthStatus.authenticated);
    expect(state.accessToken, 'access-token');
  });
}
