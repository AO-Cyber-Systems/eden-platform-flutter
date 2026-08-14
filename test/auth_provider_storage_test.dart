// Tests for AuthNotifier integration with the new TokenStorage abstraction.
//
// AuthNotifier no longer reaches for SharedPreferences directly — it consumes
// a TokenStorage via Provider, with SecureTokenStorage (flutter_secure_storage)
// as the default. Existing installs migrate transparently via the storage
// layer; AuthNotifier is unaware that migration happened.
//
// ignore_for_file: avoid_relative_lib_imports

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:eden_platform_flutter/src/errors/platform_errors.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

/// A [TokenStorage] whose reads and whose `clear()` can each be armed to
/// throw, standing in for the real-world failure where the platform channel
/// is unavailable and `SecureTokenStorage` surfaces a
/// `MissingPluginException` out of `clear()`.
///
/// This is the production shape, not a contrived one: `SecureTokenStorage`
/// swallows `flutter_secure_storage`'s own MissingPluginException and falls
/// through to `shared_preferences`, whose `getAll` then throws when no
/// implementation is registered (and on web, secure storage genuinely
/// throws). Both flags default to `false`, so the pre-existing tests in this
/// file behave exactly as they did against plain [FakeTokenStorage].
class ThrowingTokenStorage extends FakeTokenStorage {
  bool readThrows = false;
  bool clearThrows = false;

  static MissingPluginException _pluginMissing() => MissingPluginException(
        'No implementation found for method getAll on channel '
        'plugins.flutter.io/shared_preferences',
      );

  @override
  Future<String?> readRefreshToken() async {
    if (readThrows) throw _pluginMissing();
    return super.readRefreshToken();
  }

  @override
  Future<void> clear() async {
    if (clearThrows) {
      clearCalls++;
      throw _pluginMissing();
    }
    return super.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlatformRepository repository;
  late ThrowingTokenStorage storage;

  setUp(() {
    repository = FakePlatformRepository();
    storage = ThrowingTokenStorage();
  });

  ProviderContainer createContainer() {
    final c = ProviderContainer(
      overrides: [
        platformRepositoryProvider.overrideWithValue(repository),
        tokenStorageProvider.overrideWithValue(storage),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('tokenStorageProvider is exposed in the public API', () {
    // The provider must be importable from eden_platform.dart so app-side
    // consumers can override the default SecureTokenStorage with a fake.
    expect(tokenStorageProvider, isA<Provider<TokenStorage>>());
  });

  test('restoreSession reads refresh token via TokenStorage (not SharedPreferences)',
      () async {
    storage.seed(refresh: 'sealed-refresh');
    repository.refreshResult = buildSession();

    final container = createContainer();
    container.read(authProvider.notifier);
    await settle();

    expect(container.read(authProvider).status, AuthStatus.authenticated);
    expect(repository.refreshCalls, 1);
    expect(storage.readRefreshCalls, greaterThanOrEqualTo(1));
  });

  test('login persists tokens via TokenStorage', () async {
    repository.loginResult = buildSession();

    final container = createContainer();
    container.read(authProvider.notifier);
    await settle();

    await container.read(authProvider.notifier).login('a@b.com', 'pass');

    expect(storage.writeAccessCalls, greaterThanOrEqualTo(1));
    expect(storage.writeRefreshCalls, greaterThanOrEqualTo(1));
  });

  test('logout clears tokens via TokenStorage.clear()', () async {
    repository.loginResult = buildSession();
    final container = createContainer();
    container.read(authProvider.notifier);
    await settle();

    await container.read(authProvider.notifier).login('a@b.com', 'pass');
    await container.read(authProvider.notifier).logout();

    expect(storage.clearCalls, greaterThanOrEqualTo(1));
    expect(container.read(authProvider).status, AuthStatus.unauthenticated);
  });

  // restoreSession() is fired as `unawaited(...)` from the AuthNotifier
  // constructor, so anything that escapes it becomes an unhandled async error
  // with no caller to catch it. Each of its three failure branches responds by
  // clearing persisted tokens and dropping to signed-out — but the clear can
  // itself throw, and when it does it must not take the state transition down
  // with it. Every case below asserts BOTH halves: the call completes, and the
  // notifier lands in the coherent signed-out state rather than a stale or
  // half-restored one.
  group('restoreSession survives a failing token-storage clear', () {
    test('token read throws: completes and signs out even if clear() throws',
        () async {
      repository.loginResult = buildSession();
      final container = createContainer();
      final notifier = container.read(authProvider.notifier);
      await settle();

      // Establish a real authenticated session first, so the signed-out
      // assertion below is load-bearing: without the fix the notifier stays
      // stuck on this stale authenticated state.
      await notifier.login('a@b.com', 'pass');
      expect(container.read(authProvider).status, AuthStatus.authenticated);

      // Now arm the storage to fail the way a missing platform channel does:
      // the refresh-token read throws, and the cleanup clear() throws too.
      storage.readThrows = true;
      storage.clearThrows = true;

      await expectLater(notifier.restoreSession(), completes);

      expect(storage.clearCalls, greaterThanOrEqualTo(1));
      expect(container.read(authProvider).status, AuthStatus.unauthenticated);
      expect(container.read(authProvider).session, isNull);
    });

    test('refresh rejected (AuthError): completes and signs out even if clear() throws',
        () async {
      final container = createContainer();
      final notifier = container.read(authProvider.notifier);
      await settle();

      storage.seed(refresh: 'stale-refresh');
      repository.refreshError = AuthError('refresh token expired');
      storage.clearThrows = true;

      await expectLater(notifier.restoreSession(), completes);

      expect(storage.clearCalls, greaterThanOrEqualTo(1));
      expect(container.read(authProvider).status, AuthStatus.unauthenticated);
    });

    test('refresh fails unexpectedly: completes and signs out even if clear() throws',
        () async {
      final container = createContainer();
      final notifier = container.read(authProvider.notifier);
      await settle();

      storage.seed(refresh: 'stale-refresh');
      repository.refreshError = StateError('unexpected transport failure');
      storage.clearThrows = true;

      await expectLater(notifier.restoreSession(), completes);

      expect(storage.clearCalls, greaterThanOrEqualTo(1));
      expect(container.read(authProvider).status, AuthStatus.unauthenticated);
    });
  });
}
