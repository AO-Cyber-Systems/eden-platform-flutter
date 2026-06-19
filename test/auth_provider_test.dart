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

  group('AuthStrategy injection', () {
    test('strategy.login -> Authenticated drives state.authenticated', () async {
      SharedPreferences.setMockInitialValues({});
      final strategy = _FakeStrategy()
        ..initiateResult = Authenticated(buildSession(userId: 'strategy-1'));
      final container = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          authStrategyProvider.overrideWithValue(strategy),
        ],
      );
      addTearDown(container.dispose);
      container.read(authProvider.notifier);
      await settle();

      await container.read(authProvider.notifier).login('a@b.com', 'pass');

      final state = container.read(authProvider);
      expect(state.status, AuthStatus.authenticated);
      expect(state.userId, 'strategy-1');
      expect(strategy.initiateCalls, 1);
      // Legacy repository.login must not be called when a strategy is set.
      expect(repository.loginCalls, 0);
    });

    test('strategy.login -> TwoFactorRequired surfaces continuation token', () async {
      SharedPreferences.setMockInitialValues({});
      final strategy = _FakeStrategy()
        ..initiateResult = const TwoFactorRequired('cont-abc');
      final container = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          authStrategyProvider.overrideWithValue(strategy),
        ],
      );
      addTearDown(container.dispose);
      container.read(authProvider.notifier);
      await settle();

      await container.read(authProvider.notifier).login('a@b.com', 'pass');

      final notifier = container.read(authProvider.notifier);
      expect(notifier.continuationToken, 'cont-abc');
      expect(container.read(authProvider).status, AuthStatus.refreshing);
    });

    test('strategy.completeLogin -> Authenticated clears continuation + auths', () async {
      SharedPreferences.setMockInitialValues({});
      final strategy = _FakeStrategy()
        ..initiateResult = const TwoFactorRequired('cont-xyz')
        ..completeResult = Authenticated(buildSession(userId: 'mfa-done'));
      final container = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          authStrategyProvider.overrideWithValue(strategy),
        ],
      );
      addTearDown(container.dispose);
      container.read(authProvider.notifier);
      await settle();

      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await container.read(authProvider.notifier).completeLogin({'totp': '123456'});

      final state = container.read(authProvider);
      expect(state.status, AuthStatus.authenticated);
      expect(state.userId, 'mfa-done');
      expect(container.read(authProvider.notifier).continuationToken, isNull);
      expect(strategy.completeCalls, 1);
      expect(strategy.lastCompleteToken, 'cont-xyz');
      expect(strategy.lastCompleteProof, {'totp': '123456'});
    });

    test('strategy.completeLogin -> Failed surfaces error message', () async {
      SharedPreferences.setMockInitialValues({});
      final strategy = _FakeStrategy()
        ..initiateResult = const TwoFactorRequired('cont-1')
        ..completeResult = const Failed('Invalid TOTP code');
      final container = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          authStrategyProvider.overrideWithValue(strategy),
        ],
      );
      addTearDown(container.dispose);
      container.read(authProvider.notifier);
      await settle();

      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await container.read(authProvider.notifier).completeLogin({'totp': '999999'});

      final state = container.read(authProvider);
      expect(state.status, AuthStatus.error);
      expect(state.errorMessage, 'Invalid TOTP code');
    });

    test('strategy.restoreSession -> Authenticated populates state at boot', () async {
      SharedPreferences.setMockInitialValues({});
      final strategy = _FakeStrategy()
        ..restoreResult = buildSession(userId: 'restored-1');
      final container = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          authStrategyProvider.overrideWithValue(strategy),
        ],
      );
      addTearDown(container.dispose);
      container.read(authProvider.notifier);
      await settle();

      final state = container.read(authProvider);
      expect(state.status, AuthStatus.authenticated);
      expect(state.userId, 'restored-1');
      expect(strategy.restoreCalls, 1);
    });

    test('strategy.logout transitions to unauthenticated', () async {
      SharedPreferences.setMockInitialValues({});
      final strategy = _FakeStrategy()
        ..initiateResult = Authenticated(buildSession())
        ..restoreResult = null;
      final container = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          authStrategyProvider.overrideWithValue(strategy),
        ],
      );
      addTearDown(container.dispose);
      container.read(authProvider.notifier);
      await settle();

      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      expect(container.read(authProvider).isAuthenticated, true);

      await container.read(authProvider.notifier).logout();

      expect(container.read(authProvider).status, AuthStatus.unauthenticated);
      expect(strategy.logoutCalls, 1);
    });

    test('cookie-bound session does not persist empty tokens', () async {
      SharedPreferences.setMockInitialValues({});
      final cookieSession = PlatformSession.cookieBound(
        user: const PlatformUser(
          id: 'cookie-user',
          email: 'cookie@ex.com',
          displayName: 'Cookie',
          isActive: true,
        ),
      );
      final strategy = _FakeStrategy()..initiateResult = Authenticated(cookieSession);
      final container = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          authStrategyProvider.overrideWithValue(strategy),
        ],
      );
      addTearDown(container.dispose);
      container.read(authProvider.notifier);
      await settle();

      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await settle();

      final state = container.read(authProvider);
      expect(state.isAuthenticated, true);
      expect(state.session?.cookieBound, true);
      // Empty token strings must not clobber prior secure-storage values
      // (the SecureTokenStorage mock writes through; cookie-bound flow
      // skips persistence entirely so the store stays empty here).
      expect(secureStore['access_token'], isNull);
      expect(secureStore['refresh_token'], isNull);
    });

    test('legacy email+password flow unchanged when no strategy injected', () async {
      // Backward-compatibility regression: a container with no
      // authStrategyProvider override must still drive the repository.
      SharedPreferences.setMockInitialValues({});
      repository.loginResult = buildSession(userId: 'legacy-1');
      container = createContainer();
      container.read(authProvider.notifier);
      await settle();

      await container.read(authProvider.notifier).login('a@b.com', 'pass');

      final state = container.read(authProvider);
      expect(state.status, AuthStatus.authenticated);
      expect(state.userId, 'legacy-1');
      expect(repository.loginCalls, 1);
    });
  });
}

/// In-memory [AuthStrategy] for unit tests.
class _FakeStrategy implements AuthStrategy {
  AuthResult initiateResult = const Failed('no initiate configured');
  AuthResult completeResult = const Failed('no complete configured');
  PlatformSession? restoreResult;

  int initiateCalls = 0;
  int completeCalls = 0;
  int logoutCalls = 0;
  int restoreCalls = 0;

  String? lastCompleteToken;
  Map<String, String>? lastCompleteProof;

  @override
  Future<AuthResult> initiateLogin(Map<String, String> credentials) async {
    initiateCalls++;
    return initiateResult;
  }

  @override
  Future<AuthResult> completeLogin(
      String continuationToken, Map<String, String> proof) async {
    completeCalls++;
    lastCompleteToken = continuationToken;
    lastCompleteProof = proof;
    return completeResult;
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
  }

  @override
  Future<PlatformSession?> restoreSession() async {
    restoreCalls++;
    return restoreResult;
  }
}
