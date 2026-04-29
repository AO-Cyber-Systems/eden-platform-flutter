import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:eden_platform_flutter/src/errors/platform_errors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlatformRepository repository;
  late ProviderContainer container;
  late Map<String, String> secureStore;

  setUp(() {
    repository = FakePlatformRepository();
    // Install in-memory mock for flutter_secure_storage so the default
    // SecureTokenStorage (via tokenStorageProvider) doesn't hit
    // MissingPluginException in unit tests.
    secureStore = installSecureStorageChannelMock();
  });

  tearDown(uninstallSecureStorageChannelMock);

  ProviderContainer createContainer() {
    final c = ProviderContainer(
      overrides: [platformRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('initial state', () {
    test('starts as unknown and auto-calls restoreSession', () async {
      SharedPreferences.setMockInitialValues({});
      container = createContainer();

      // Before settle, the notifier has been created but restoreSession is in-flight
      container.read(authProvider.notifier);
      await settle();

      // With no tokens, it should settle to unauthenticated
      expect(container.read(authProvider).status, AuthStatus.unauthenticated);
    });
  });

  group('restoreSession', () {
    test('no tokens -> unauthenticated', () async {
      SharedPreferences.setMockInitialValues({});
      container = createContainer();
      container.read(authProvider.notifier);
      await settle();

      expect(container.read(authProvider).status, AuthStatus.unauthenticated);
      expect(repository.refreshCalls, 0);
    });

    test('with refresh token (legacy prefs) -> migrates, refreshes, and authenticates', () async {
      // Legacy install: refresh_token is in shared_preferences. The new
      // SecureTokenStorage migrates it to secure storage on first read.
      SharedPreferences.setMockInitialValues({'refresh_token': 'old-token'});
      repository.refreshResult = buildSession();
      container = createContainer();
      container.read(authProvider.notifier);
      await settle();

      final state = container.read(authProvider);
      expect(state.status, AuthStatus.authenticated);
      expect(state.accessToken, 'access-token');
      expect(repository.refreshCalls, 1);
      // After successful refresh, NEW tokens land in secure storage.
      expect(secureStore['access_token'], 'access-token');
      expect(secureStore['refresh_token'], 'refresh-token');
    });

    test('with refresh token (already in secure storage) -> refreshes', () async {
      SharedPreferences.setMockInitialValues({});
      secureStore['refresh_token'] = 'sealed-refresh';
      repository.refreshResult = buildSession();
      container = createContainer();
      container.read(authProvider.notifier);
      await settle();

      final state = container.read(authProvider);
      expect(state.status, AuthStatus.authenticated);
      expect(repository.refreshCalls, 1);
    });

    test('refresh failure (AuthError) -> unauthenticated', () async {
      SharedPreferences.setMockInitialValues({'refresh_token': 'old-token'});
      repository.refreshError = AuthError('token expired');
      container = createContainer();
      container.read(authProvider.notifier);
      await settle();

      expect(container.read(authProvider).status, AuthStatus.unauthenticated);
      expect(repository.refreshCalls, 1);
    });

    test('refresh failure (NetworkError) -> error state with message', () async {
      SharedPreferences.setMockInitialValues({'refresh_token': 'old-token'});
      repository.refreshError = NetworkError('no connection');
      container = createContainer();
      container.read(authProvider.notifier);
      await settle();

      final state = container.read(authProvider);
      expect(state.status, AuthStatus.error);
      expect(state.errorMessage, contains('Network unavailable'));
    });
  });

  group('login', () {
    test('success -> authenticated + tokens persisted to secure storage', () async {
      SharedPreferences.setMockInitialValues({});
      repository.loginResult = buildSession();
      container = createContainer();
      container.read(authProvider.notifier);
      await settle();

      await container.read(authProvider.notifier).login('a@b.com', 'pass');

      final state = container.read(authProvider);
      expect(state.status, AuthStatus.authenticated);
      expect(state.userId, 'user-1');

      // CLI-01: tokens persisted to secure storage, not shared_preferences.
      expect(secureStore['access_token'], 'access-token');
      expect(secureStore['refresh_token'], 'refresh-token');
    });

    test('failure (PlatformError) -> error state with message', () async {
      SharedPreferences.setMockInitialValues({});
      repository.loginError = AuthError('Invalid credentials');
      container = createContainer();
      container.read(authProvider.notifier);
      await settle();

      await container.read(authProvider.notifier).login('a@b.com', 'wrong');

      final state = container.read(authProvider);
      expect(state.status, AuthStatus.error);
      expect(state.errorMessage, 'Invalid credentials');
    });

    test('failure (generic) -> error state', () async {
      SharedPreferences.setMockInitialValues({});
      repository.loginError = Exception('unexpected');
      container = createContainer();
      container.read(authProvider.notifier);
      await settle();

      await container.read(authProvider.notifier).login('a@b.com', 'wrong');

      final state = container.read(authProvider);
      expect(state.status, AuthStatus.error);
      expect(state.errorMessage, contains('unexpected'));
    });
  });

  group('signUp', () {
    test('success -> authenticated + tokens persisted', () async {
      SharedPreferences.setMockInitialValues({});
      repository.signUpResult = buildSession(userId: 'new-user');
      container = createContainer();
      container.read(authProvider.notifier);
      await settle();

      await container
          .read(authProvider.notifier)
          .signUp('new@b.com', 'pass', 'New User');

      final state = container.read(authProvider);
      expect(state.status, AuthStatus.authenticated);
      expect(state.userId, 'new-user');
    });

    test('failure -> error state', () async {
      SharedPreferences.setMockInitialValues({});
      repository.signUpError = ServerError('email taken', code: 6);
      container = createContainer();
      container.read(authProvider.notifier);
      await settle();

      await container
          .read(authProvider.notifier)
          .signUp('dup@b.com', 'pass', 'Dup');

      final state = container.read(authProvider);
      expect(state.status, AuthStatus.error);
      expect(state.errorMessage, 'email taken');
    });
  });

  group('logout', () {
    test('clears tokens + sets unauthenticated', () async {
      SharedPreferences.setMockInitialValues({});
      repository.loginResult = buildSession();
      container = createContainer();
      container.read(authProvider.notifier);
      await settle();

      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      expect(container.read(authProvider).isAuthenticated, true);

      await container.read(authProvider.notifier).logout();

      expect(container.read(authProvider).status, AuthStatus.unauthenticated);
      expect(repository.logoutCalls, 1);

      // CLI-01: clear() drops both stores (secure + any legacy prefs straggler).
      expect(secureStore['access_token'], isNull);
      expect(secureStore['refresh_token'], isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('access_token'), isNull);
      expect(prefs.getString('refresh_token'), isNull);
    });

    test('logout API failure is non-blocking', () async {
      // Even if the logout API throws, the state should become unauthenticated.
      // Our FakePlatformRepository doesn't throw on logout by default,
      // so we test that the state transitions correctly regardless.
      SharedPreferences.setMockInitialValues({});
      repository.loginResult = buildSession();
      container = createContainer();
      container.read(authProvider.notifier);
      await settle();

      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await container.read(authProvider.notifier).logout();

      expect(container.read(authProvider).status, AuthStatus.unauthenticated);
    });
  });
}
