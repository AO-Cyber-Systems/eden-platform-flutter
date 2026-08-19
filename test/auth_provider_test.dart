import 'dart:async';
import 'dart:io';

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

    // --- AOID the spec: the widened AuthResult family ---

    test('RedirectRequired does not put the notifier into an error state — a '
        'browser hop is a first-class path', () async {
      SharedPreferences.setMockInitialValues({});
      final authorizationUrl = Uri.parse(
        'https://auth.aocyber.ai/oauth/authorize'
        '?client_id=aodex&response_type=code&state=xyz',
      );
      final strategy = _FakeStrategy()
        ..initiateResult = RedirectRequired(
          authorizationUrl,
          reason: 'redirect_to_web',
        );
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
      // The defect this work removes: a user who merely needs a browser hop
      // being shown "login failed".
      expect(state.status, isNot(AuthStatus.error));
      expect(state.errorMessage, isNull);
      // …and it must not silently strand the UI either. Refreshing is the
      // "ceremony in flight" state the MFA path already uses.
      expect(state.status, AuthStatus.refreshing);
      // The URL has to actually reach the UI, or the hop cannot be opened.
      expect(
        container.read(authProvider.notifier).pendingRedirectUrl,
        authorizationUrl,
      );
    });

    test('a subsequent result clears the pending redirect URL, so a stale hop '
        'can never be opened after the ceremony moves on', () async {
      SharedPreferences.setMockInitialValues({});
      final strategy = _RecordingStrategy(
        initiate: RedirectRequired(
          Uri.parse('https://auth.aocyber.ai/oauth/authorize?state=stale'),
        ),
        completions: <AuthResult>[const Failed('user abandoned the hop')],
      );
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
      expect(
        container.read(authProvider.notifier).pendingRedirectUrl,
        isNotNull,
      );

      // A redirect carries no continuation handle, so drive the next result
      // through initiateLogin again rather than completeLogin.
      strategy.initiate = const Failed('user abandoned the hop');
      await container.read(authProvider.notifier).login('a@b.com', 'pass');

      expect(container.read(authProvider.notifier).pendingRedirectUrl, isNull);
      expect(container.read(authProvider).status, AuthStatus.error);
    });

    test('rotation across sequential completeLogin: the SECOND call presents '
        'the ROTATED handle, not the original (the issuer rotates auth_session on '
        'every step)', () async {
      SharedPreferences.setMockInitialValues({});
      // Hand-built. Records what it is presented so the test can assert the
      // SECOND completeLogin receives the ROTATED handle, not the original.
      final strategy = _RecordingStrategy(
        initiate: const FactorRequired(
          continuationToken: 'h1',
          next: 'password',
          availableMethods: ['password'],
        ),
        completions: <AuthResult>[
          // Step 1 succeeds and the server hands back a NEW handle plus the
          // methods the identity can use for the next factor.
          const FactorRequired(
            continuationToken: 'h2',
            next: 'mfa',
            availableMethods: ['totp', 'backup_code'],
          ),
          Authenticated(buildSession(userId: 'rotated-done')),
        ],
      );
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
      expect(container.read(authProvider.notifier).continuationToken, 'h1');

      await container
          .read(authProvider.notifier)
          .completeLogin({'password': 'pw'});
      expect(container.read(authProvider.notifier).continuationToken, 'h2');

      await container
          .read(authProvider.notifier)
          .completeLogin({'totp': '123456'});

      // The SEQUENCE is the assertion. A test that only checked "login
      // completed" would pass even if the handle never rotated.
      expect(strategy.presented, ['h1', 'h2']);
      expect(container.read(authProvider).status, AuthStatus.authenticated);
      expect(container.read(authProvider).userId, 'rotated-done');
      expect(container.read(authProvider.notifier).continuationToken, isNull);
    });

    test('a mid-ceremony FactorRequired surfaces next + availableMethods so '
        'the UI can render a factor picker', () async {
      SharedPreferences.setMockInitialValues({});
      const factor = FactorRequired(
        continuationToken: 'as_2',
        next: 'mfa',
        availableMethods: ['totp', 'webauthn'],
      );
      final strategy = _FakeStrategy()..initiateResult = factor;
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

      expect(container.read(authProvider).status, AuthStatus.refreshing);
      expect(container.read(authProvider.notifier).continuationToken, 'as_2');
      // The picker data itself rides on the result, not on AuthState — the spec
      // AoidMfaForm reads it from the FactorRequired the strategy returned.
      expect(factor.next, 'mfa');
      expect(factor.availableMethods, ['totp', 'webauthn']);
    });

    test('a terminal Failed clears the continuation token, so a later '
        'completeLogin throws StateError rather than replaying a dead handle',
        () async {
      SharedPreferences.setMockInitialValues({});
      final strategy = _RecordingStrategy(
        initiate: const FactorRequired(continuationToken: 'h1', next: 'mfa'),
        completions: <AuthResult>[const Failed('Invalid TOTP code')],
      );
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
      await container
          .read(authProvider.notifier)
          .completeLogin({'totp': '999999'});

      expect(container.read(authProvider).status, AuthStatus.error);
      expect(container.read(authProvider.notifier).continuationToken, isNull);
      await expectLater(
        container.read(authProvider.notifier).completeLogin({'totp': '000000'}),
        throwsStateError,
      );
      // The dead handle was presented exactly once — never replayed.
      expect(strategy.presented, ['h1']);
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

  // ===================================================================
  // AOID, the spec — the riverpod 3 `Notifier` port.
  //
  // AuthNotifier moved from `StateNotifier<AuthState>` (flutter_riverpod's
  // legacy.dart shim) to `Notifier<AuthState>`, and `authProvider` from
  // `StateNotifierProvider` to `NotifierProvider`. The base class changed;
  // no auth behaviour did. These tests pin the three things the swap could
  // silently break, each against a fixture where the defect WOULD have shown.
  // ===================================================================

  group('the spec riverpod 3 Notifier port', () {
    test('authProvider resolves an AuthNotifier whose three dependencies came '
        'from build(), and whose initial state is unknown', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = FakeTokenStorage();
      final strategy = _FakeStrategy();
      final c = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          tokenStorageProvider.overrideWithValue(storage),
          authStrategyProvider.overrideWithValue(strategy),
        ],
      );
      addTearDown(c.dispose);

      // The FIRST read must be the state, not the notifier: build() supplies
      // both, and reading state first proves build() ran and returned the
      // initial value rather than a constructor having set it.
      expect(c.read(authProvider).status, AuthStatus.unknown);
      expect(c.read(authProvider.notifier), isA<AuthNotifier>());

      // Constructor injection is gone, so the only evidence the dependencies
      // arrived is that the notifier behaves as though they did. The strategy
      // override is the observable one.
      expect(c.read(authProvider.notifier).usesStrategy, true);
      await settle();
      //...and it actually drove the injected strategy, not the repository.
      expect(strategy.restoreCalls, 1);
      expect(repository.refreshCalls, 0);
    });

    test('login walks unknown -> refreshing -> authenticated, and the '
        'intermediate refreshing state is actually observed', () async {
      SharedPreferences.setMockInitialValues({});
      repository.loginResult = buildSession();
      final c = createContainer();
      final seen = <AuthStatus>[];
      c.listen<AuthState>(authProvider, (_, next) => seen.add(next.status));
      await settle();
      seen.clear();

      await c.read(authProvider.notifier).login('a@b.com', 'pass');

      // The SEQUENCE is the assertion. Asserting only the terminal state would
      // pass even if the notifier jumped straight there and never told the UI
      // a login was in flight.
      expect(seen, [AuthStatus.refreshing, AuthStatus.authenticated]);
    });

    test('a login failure walks refreshing -> error with the message preserved',
        () async {
      SharedPreferences.setMockInitialValues({});
      repository.loginError = AuthError('Invalid credentials');
      final c = createContainer();
      final seen = <AuthState>[];
      c.listen<AuthState>(authProvider, (_, next) => seen.add(next));
      await settle();
      seen.clear();

      await c.read(authProvider.notifier).login('a@b.com', 'nope');

      expect(seen.map((s) => s.status).toList(),
          [AuthStatus.refreshing, AuthStatus.error]);
      expect(seen.last.errorMessage, 'Invalid credentials');
    });

    // ---- The load-bearing one: the sign-out notification ----------------

    test('PREMISE: the AuthState sentinels are const-canonicalized and '
        'AuthState has no value ==', () {
      // Guards the two tests below. If either premise ever stops holding, the
      // notification tests could pass for a reason that has nothing to do with
      // what they claim to prove.
      expect(
        identical(const AuthState.unauthenticated(),
            const AuthState.unauthenticated()),
        true,
        reason: 'const instances must canonicalize to one object',
      );
      expect(identical(const AuthState.unknown(), const AuthState.unknown()),
          true);
      // No value ==: two structurally identical NON-const instances compare
      // unequal. This is why riverpod 3's `==` filter and StateNotifier's
      // `!identical` filter are the same predicate for this class.
      expect(AuthState.refreshing(session: null) ==
          AuthState.refreshing(session: null), false);
    });

    test('a repeated sign-out still notifies listeners, even though the state '
        'is the identical const sentinel both times', () async {
      SharedPreferences.setMockInitialValues({});
      final c = createContainer();
      final fires = <AuthStatus>[];
      c.listen<AuthState>(authProvider, (_, next) => fires.add(next.status));
      await settle();
      final n = c.read(authProvider.notifier);
      fires.clear();

      await n.logout();
      await n.logout();

      // The fixture is deliberately one where the defect WOULD show: the boot
      // already settled to unauthenticated, so BOTH assignments are the
      // identical canonical object and the default `==`/`identical` filter
      // drops both. Measured on the pre-port StateNotifier: fires == [].
      expect(fires.length, 2,
          reason: 'updateShouldNotify must restore the riverpod-2 signal; '
              'a filtered sign-out leaves downstream state resident');
    });

    test('a listener shaped like company/nav/entitlements observes the '
        'sign-out even when the prior state was already unauthenticated',
        () async {
      SharedPreferences.setMockInitialValues({});
      repository.loginResult = buildSession();
      final c = createContainer();
      // Replicated INLINE. company_provider, nav_provider and
      // entitlements_provider are owned by other work in this same wave, so
      // this must not import them — but this is their exact listener shape.
      var clears = 0;
      c.listen<AuthState>(authProvider, (previous, next) {
        if (!next.isAuthenticated) {
          clears++;
          return;
        }
      });
      await settle();
      final n = c.read(authProvider.notifier);

      await n.login('a@b.com', 'pass');
      expect(c.read(authProvider).isAuthenticated, true);
      clears = 0;

      await n.logout();
      expect(clears, 1, reason: 'the real sign-out must clear downstream state');

      // The second sign-out is the exposure case: an app that signs out twice
      // (interceptor-driven logout racing a user-driven one) must still push
      // the clear, because a listener that missed the first would otherwise
      // never hear one at all.
      await n.logout();
      expect(clears, 2);
    });

    // ---- Notifier-instance lifetime, and the fields outside `state` -------

    test('PREMISE: riverpod 3 REUSES the notifier instance across a rebuild',
        () async {
      SharedPreferences.setMockInitialValues({});
      final c = createContainer();
      c.listen<AuthState>(authProvider, (_, _) {});
      await settle();
      final first = c.read(authProvider.notifier);
      c.invalidate(authProvider);
      await settle();
      final second = c.read(authProvider.notifier);

      // This is the opposite of what StateNotifierProvider did (measured:
      // identical == false, because its create callback ran the constructor
      // again). It is why build() has to reset the ceremony fields by hand.
      expect(identical(first, second), true);
    });

    test('a rebuild clears the in-flight ceremony state — a continuation token '
        'must not outlive the rebuild that discarded its ceremony', () async {
      SharedPreferences.setMockInitialValues({});
      final strategy = _FakeStrategy()
        ..initiateResult = const FactorRequired(
          continuationToken: 'as_survivor',
          next: 'mfa',
          availableMethods: ['totp'],
        );
      final c = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          authStrategyProvider.overrideWithValue(strategy),
        ],
      );
      addTearDown(c.dispose);
      c.listen<AuthState>(authProvider, (_, _) {});
      await settle();

      await c.read(authProvider.notifier).login('a@b.com', 'pass');
      // The fixture where the defect WOULD show: a token that really is
      // present before the rebuild. Asserting null after an invalidate on a
      // notifier that never held one would be vacuous.
      expect(c.read(authProvider.notifier).continuationToken, 'as_survivor');

      c.invalidate(authProvider);
      await settle();

      expect(c.read(authProvider.notifier).continuationToken, isNull,
          reason: 'the instance is REUSED, so only build() clears this; '
              'the issuer rotates auth_session per step and a surviving '
              'handle belongs to an abandoned ceremony');
      // The dead handle must also be unusable, not merely unreadable.
      await expectLater(
        c.read(authProvider.notifier).completeLogin({'totp': '000000'}),
        throwsStateError,
      );
    });

    test('a rebuild clears the pending redirect URL, so a stale browser hop '
        'cannot be opened after the rebuild', () async {
      SharedPreferences.setMockInitialValues({});
      final url = Uri.parse('https://auth.aocyber.ai/oauth/authorize?state=s1');
      final strategy = _FakeStrategy()..initiateResult = RedirectRequired(url);
      final c = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          authStrategyProvider.overrideWithValue(strategy),
        ],
      );
      addTearDown(c.dispose);
      c.listen<AuthState>(authProvider, (_, _) {});
      await settle();

      await c.read(authProvider.notifier).login('a@b.com', 'pass');
      expect(c.read(authProvider.notifier).pendingRedirectUrl, url);

      c.invalidate(authProvider);
      await settle();

      expect(c.read(authProvider.notifier).pendingRedirectUrl, isNull);
    });

    // ---- The boot side effect, moved constructor -> build() --------------

    test('restoreSession runs exactly once per provider build — the cadence '
        'the StateNotifierProvider had', () async {
      SharedPreferences.setMockInitialValues({});
      final strategy = _FakeStrategy();
      final c = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          authStrategyProvider.overrideWithValue(strategy),
        ],
      );
      addTearDown(c.dispose);
      c.listen<AuthState>(authProvider, (_, _) {});
      await settle();

      // Once for the initial build. `greaterThanOrEqualTo(1)` would pass on a
      // notifier that restored on every state change, so this is exact.
      expect(strategy.restoreCalls, 1);

      c.invalidate(authProvider);
      await settle();
      expect(strategy.restoreCalls, 2);

      // Reading state repeatedly must NOT re-trigger it.
      c.read(authProvider);
      c.read(authProvider);
      await settle();
      expect(strategy.restoreCalls, 2);
    });

    test('restoreSession swallows a token-storage read failure and lands on '
        'unauthenticated rather than hanging in unknown', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = _ThrowingTokenStorage();
      final c = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          tokenStorageProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(c.dispose);
      c.listen<AuthState>(authProvider, (_, _) {});
      await settle();

      // The file's own comment: an unhandled throw here "leaves auth stuck in
      // `unknown` forever, hanging every gated route behind a spinner".
      expect(c.read(authProvider).status, AuthStatus.unauthenticated);
      expect(storage.readRefreshCalls, 1);
      //...and it clears rather than leaving an unreadable token behind.
      expect(storage.clearCalls, greaterThanOrEqualTo(1));
    });

    // ---- Post-disposal safety (riverpod 3 throws where 2 tolerated) ------

    test('an async tail that completes AFTER the container is disposed does '
        'not throw — riverpod 3 rejects post-disposal ref/state use', () async {
      SharedPreferences.setMockInitialValues({});
      final gate = Completer<PlatformSession>();
      final slow = _GatedRepository(gate);
      final c = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(slow)],
      );
      c.listen<AuthState>(authProvider, (_, _) {});
      await settle();

      // Start a login and leave it parked mid-await.
      final pending = c.read(authProvider.notifier).login('a@b.com', 'pass');
      await settle();

      // Dispose while the repository call is still in flight. This is the
      // fixture where the defect WOULD show: without the ref.mounted guard the
      // completion below assigns `state` on a disposed element and throws.
      c.dispose();
      gate.complete(buildSession());

      await expectLater(pending, completes);
    });

    test('restoreSession tolerates disposal while the token-storage read is '
        'still in flight, on BOTH the success and the failure tail', () async {
      // Added because a mutation SURVIVED: deleting restoreSession's own
      // ref.mounted guards changed nothing, since the disposal test above only
      // exercises login's repository tail. Each async tail needs its own
      // fixture.
      SharedPreferences.setMockInitialValues({});
      for (final failTheRead in [false, true]) {
        final gate = Completer<String?>();
        final storage = _GatedTokenStorage(gate);
        final c = ProviderContainer(
          overrides: [
            platformRepositoryProvider.overrideWithValue(repository),
            tokenStorageProvider.overrideWithValue(storage),
          ],
        );
        c.listen<AuthState>(authProvider, (_, _) {});
        await settle();

        final pending = c.read(authProvider.notifier).restoreSession();
        await settle();

        c.dispose();
        if (failTheRead) {
          gate.completeError(StateError('secure storage vanished'));
        } else {
          gate.complete('a-refresh-token');
        }

        await expectLater(pending, completes,
            reason: 'failTheRead=$failTheRead must not throw after disposal');
      }
    });

    test('a strategy login that resolves AFTER disposal writes no tokens — a '
        'torn-down notifier must not persist credentials', () async {
      // Added to close a SURVIVING mutation, and it took two attempts. The
      // obvious assertion ("the future completes without throwing") CANNOT
      // detect a missing guard here: without it, `_applyAuthResult` throws on
      // the disposed element and login's own `catch (error)` swallows it, so
      // the future completes either way. The observable difference is the side
      // effect that runs BEFORE the state assignment — `_persistTokens`.
      SharedPreferences.setMockInitialValues({});

      // CONTROL first: the same flow, NOT disposed, really does write. Without
      // this the zero-write assertion below could pass for any reason at all.
      final liveStorage = FakeTokenStorage();
      final liveGate = Completer<AuthResult>();
      final live = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          tokenStorageProvider.overrideWithValue(liveStorage),
          authStrategyProvider.overrideWithValue(_GatedStrategy(liveGate)),
        ],
      );
      addTearDown(live.dispose);
      live.listen<AuthState>(authProvider, (_, _) {});
      await settle();
      final livePending =
          live.read(authProvider.notifier).login('a@b.com', 'pass');
      await settle();
      liveGate.complete(Authenticated(buildSession()));
      await livePending;
      await settle();
      expect(liveStorage.writeAccessCalls, greaterThanOrEqualTo(1),
          reason: 'CONTROL: an undisposed strategy login must persist tokens, '
              'or the zero-write assertion below proves nothing');

      // Now the real case: dispose mid-flight.
      final storage = FakeTokenStorage();
      final gate = Completer<AuthResult>();
      final c = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          tokenStorageProvider.overrideWithValue(storage),
          authStrategyProvider.overrideWithValue(_GatedStrategy(gate)),
        ],
      );
      c.listen<AuthState>(authProvider, (_, _) {});
      await settle();

      final pending = c.read(authProvider.notifier).login('a@b.com', 'pass');
      await settle();

      c.dispose();
      gate.complete(Authenticated(buildSession()));

      await expectLater(pending, completes);
      await settle();
      expect(storage.writeAccessCalls, 0,
          reason: 'the ref.mounted guard must stop the disposed notifier '
              'before it persists a session nobody is listening to');
      expect(storage.writeRefreshCalls, 0);
    });

    test('logout clears a pending continuation token, so signing out mid-MFA '
        'cannot leave a live auth_session handle behind', () async {
      // Added to close a SURVIVING mutation: nothing asserted that logout
      // clears the handle. The fixture deliberately HAS a live token before
      // the logout — asserting null against a notifier that never held one
      // would be vacuous.
      SharedPreferences.setMockInitialValues({});
      final strategy = _FakeStrategy()
        ..initiateResult = const FactorRequired(
          continuationToken: 'as_live',
          next: 'mfa',
          availableMethods: ['totp'],
        );
      final c = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          authStrategyProvider.overrideWithValue(strategy),
        ],
      );
      addTearDown(c.dispose);
      c.listen<AuthState>(authProvider, (_, _) {});
      await settle();
      final n = c.read(authProvider.notifier);

      await n.login('a@b.com', 'pass');
      expect(n.continuationToken, 'as_live',
          reason: 'the fixture must actually hold a handle before the logout');

      await n.logout();

      expect(n.continuationToken, isNull);
      expect(strategy.logoutCalls, 1);
      // The abandoned handle must also be unusable, not merely hidden.
      await expectLater(
        n.completeLogin({'totp': '000000'}),
        throwsStateError,
      );
    });

    // ---- The remaining public surface, unchanged by the port -------------

    test('rotateTokens updates the live session and persists the new pair',
        () async {
      SharedPreferences.setMockInitialValues({});
      final storage = FakeTokenStorage();
      repository.loginResult = buildSession();
      final c = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          tokenStorageProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(c.dispose);
      c.listen<AuthState>(authProvider, (_, _) {});
      await settle();
      final n = c.read(authProvider.notifier);

      await n.login('a@b.com', 'pass');
      await n.rotateTokens(accessToken: 'at-2', refreshToken: 'rt-2');

      final s = c.read(authProvider);
      expect(s.accessToken, 'at-2');
      expect(s.refreshToken, 'rt-2');
      // The same human, carried across the rotation.
      expect(s.userId, 'user-1');
      expect(s.companyId, 'company-1');
      expect(storage.writeAccessCalls, greaterThanOrEqualTo(2));
    });

    test('rotateTokens is a no-op when there is no session', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = FakeTokenStorage();
      final c = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          tokenStorageProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(c.dispose);
      c.listen<AuthState>(authProvider, (_, _) {});
      await settle();
      expect(c.read(authProvider).session, isNull);

      await c
          .read(authProvider.notifier)
          .rotateTokens(accessToken: 'at-x', refreshToken: 'rt-x');

      // No session to update, so nothing is written and nothing is faked into
      // existence. Asserting only "did not throw" would miss a notifier that
      // fabricated a session from the token pair alone.
      expect(c.read(authProvider).session, isNull);
      expect(c.read(authProvider).status, AuthStatus.unauthenticated);
      expect(storage.writeAccessCalls, 0);
    });

    test('replaceSession swaps the token pair and company while preserving the '
        'user', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = FakeTokenStorage();
      repository.loginResult = buildSession();
      final c = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          tokenStorageProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(c.dispose);
      c.listen<AuthState>(authProvider, (_, _) {});
      await settle();
      final n = c.read(authProvider.notifier);

      await n.login('a@b.com', 'pass');
      await n.replaceSession(
        accessToken: 'at-co2',
        refreshToken: 'rt-co2',
        companyId: 'company-2',
        role: 'member',
      );

      final s = c.read(authProvider);
      expect(s.accessToken, 'at-co2');
      expect(s.companyId, 'company-2');
      expect(s.role, 'member');
      expect(s.userId, 'user-1');
    });

    test('updateProfile refreshes the user without disturbing the tokens, and '
        'rethrows on failure without changing auth state', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = _ProfileRepository();
      repo.loginResult = buildSession();
      final c = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(c.dispose);
      c.listen<AuthState>(authProvider, (_, _) {});
      await settle();
      final n = c.read(authProvider.notifier);

      await n.login('a@b.com', 'pass');
      await n.updateProfile('Renamed', 'https://cdn/x.png');

      expect(c.read(authProvider).user?.displayName, 'Renamed');
      expect(c.read(authProvider).accessToken, 'access-token');

      repo.profileError = ServerError('nope', code: 2);
      await expectLater(
        n.updateProfile('Again', 'https://cdn/y.png'),
        throwsA(isA<ServerError>()),
      );
      // Unchanged: a failed profile edit must not sign anyone out.
      expect(c.read(authProvider).status, AuthStatus.authenticated);
      expect(c.read(authProvider).user?.displayName, 'Renamed');
    });

    // ---- Source-level: the Stage A shim is gone --------------------------

    test('auth_provider.dart imports no legacy.dart shim and declares no '
        'StateNotifier — Stage A is finished for this file', () {
      final src = File('lib/src/auth/auth_provider.dart').readAsStringSync();
      // Fixture guard: silence must not be vacuous.
      expect(src.length, greaterThan(5000),
          reason: 'the file must actually have been read');
      expect(src, contains('class AuthNotifier extends Notifier<AuthState>'));
      expect(src, contains('NotifierProvider<AuthNotifier, AuthState>'));

      // A whole-file grep cannot tell a DECLARATION from a MENTION, and this
      // file deliberately names the old base class in comments to explain why
      // build() resets the ceremony fields. So strip comments first and assert
      // against CODE only. The banned identifiers are assembled at runtime so
      // this test file does not match its own rule and needs no self-exclusion.
      final code = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      // Guard the stripper itself: it must remove commentary without eating
      // the code, or the assertions below pass vacuously.
      expect(code.contains('class AuthNotifier extends Notifier<AuthState>'),
          true,
          reason: 'comment-stripping must not remove the declaration');
      expect(code.length, lessThan(src.length),
          reason: 'comment-stripping must actually have removed something');

      final legacyImport = "flutter_riverpod/${'legacy'}.dart";
      expect(code.contains(legacyImport), false,
          reason: 'the Stage A legacy shim import must be gone');
      final banned = ['State', 'Notifier'].join();
      expect(code.contains(banned), false,
          reason: 'no $banned may remain in the CODE of the epicentre '
              '(comments may still reference it as history)');
      //...and the shim must be gone from the comments too, not merely unused.
      expect(src.contains("import 'package:$legacyImport'"), false);
    });
  });
}

/// [TokenStorage] whose read throws, to drive `restoreSession`'s defensive
/// path. Hand-built: the point is a read that FAILS, which no fake in
/// test_helpers.dart offers.
class _ThrowingTokenStorage implements TokenStorage {
  int readRefreshCalls = 0;
  int clearCalls = 0;

  @override
  Future<String?> readAccessToken() async => null;

  @override
  Future<String?> readRefreshToken() async {
    readRefreshCalls++;
    throw StateError('secure storage unavailable');
  }

  @override
  Future<void> writeAccessToken(String? value) async {}

  @override
  Future<void> writeRefreshToken(String? value) async {}

  @override
  Future<void> clear() async {
    clearCalls++;
  }
}

/// [TokenStorage] whose read parks on a [Completer], so a test can dispose the
/// container while `restoreSession` is mid-await and prove that tail's
/// post-disposal guards hold. The gate can be completed with a value or an
/// error, covering both of `restoreSession`'s storage-read tails.
class _GatedTokenStorage implements TokenStorage {
  _GatedTokenStorage(this.gate);

  final Completer<String?> gate;

  @override
  Future<String?> readAccessToken() async => null;

  @override
  Future<String?> readRefreshToken() => gate.future;

  @override
  Future<void> writeAccessToken(String? value) async {}

  @override
  Future<void> writeRefreshToken(String? value) async {}

  @override
  Future<void> clear() async {}
}

/// [AuthStrategy] whose `initiateLogin` parks on a [Completer], covering the
/// strategy branch of `login` that the repository-backed fixture cannot reach.
class _GatedStrategy implements AuthStrategy {
  _GatedStrategy(this.gate);

  final Completer<AuthResult> gate;

  @override
  Future<AuthResult> initiateLogin(Map<String, String> credentials) =>
      gate.future;

  @override
  Future<AuthResult> completeLogin(String t, Map<String, String> p) async =>
      const Failed('not used');

  @override
  Future<void> logout() async {}

  @override
  Future<PlatformSession?> restoreSession() async => null;
}

/// Repository whose `login` parks on a [Completer], so a test can dispose the
/// container while the notifier is mid-await and prove the post-disposal
/// guards hold.
class _GatedRepository extends FakePlatformRepository {
  _GatedRepository(this.gate);

  final Completer<PlatformSession> gate;

  @override
  Future<PlatformSession> login(String email, String password) => gate.future;
}

/// Repository that supports `updateProfile`, which the base fake throws on.
class _ProfileRepository extends FakePlatformRepository {
  Object? profileError;

  @override
  Future<PlatformUser> updateProfile(
      String accessToken, String displayName, String avatarUrl) async {
    if (profileError != null) throw profileError!;
    return PlatformUser(
      id: 'user-1',
      email: 'dev@example.com',
      displayName: displayName,
      isActive: true,
    );
  }
}

/// Hand-built [AuthStrategy] that RECORDS every continuation token it is
/// presented and serves a scripted sequence of results, one per
/// [completeLogin] call. Written out literally rather than generated — the
/// point is to assert the SEQUENCE of presented handles, which is the only
/// thing that distinguishes real `auth_session` rotation from a
/// notifier that happens to complete a login.
class _RecordingStrategy implements AuthStrategy {
  _RecordingStrategy({
    required this.initiate,
    required List<AuthResult> completions,
  }) : _completions = List<AuthResult>.of(completions);

  AuthResult initiate;
  final List<AuthResult> _completions;

  /// Every `continuationToken` handed to [completeLogin], in order.
  final List<String> presented = <String>[];

  @override
  Future<AuthResult> initiateLogin(Map<String, String> credentials) async =>
      initiate;

  @override
  Future<AuthResult> completeLogin(
    String continuationToken,
    Map<String, String> proof,
  ) async {
    presented.add(continuationToken);
    if (_completions.isEmpty) {
      return const Failed('scripted completions exhausted');
    }
    return _completions.removeAt(0);
  }

  @override
  Future<void> logout() async {}

  @override
  Future<PlatformSession?> restoreSession() async => null;
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
