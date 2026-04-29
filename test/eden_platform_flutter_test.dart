import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> secureStore;

  setUp(() {
    secureStore = installSecureStorageChannelMock();
  });

  tearDown(uninstallSecureStorageChannelMock);

  test('restoreSession without persisted tokens becomes unauthenticated', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = FakePlatformRepository();
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
    final repository = FakePlatformRepository()..loginResult = buildSession();
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

    // CLI-01: tokens persist to secure storage, not shared_preferences.
    expect(secureStore['access_token'], 'access-token');
    expect(secureStore['refresh_token'], 'refresh-token');
  });

  test('restoreSession refreshes persisted tokens', () async {
    SharedPreferences.setMockInitialValues({
      'refresh_token': 'existing-refresh',
    });
    final repository = FakePlatformRepository()..refreshResult = buildSession();
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
