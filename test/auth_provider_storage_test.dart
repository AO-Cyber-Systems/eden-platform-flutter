// Tests for AuthNotifier integration with the new TokenStorage abstraction.
//
// AuthNotifier no longer reaches for SharedPreferences directly — it consumes
// a TokenStorage via Provider, with SecureTokenStorage (flutter_secure_storage)
// as the default. Existing installs migrate transparently via the storage
// layer; AuthNotifier is unaware that migration happened.
//
// ignore_for_file: avoid_relative_lib_imports

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:eden_platform_flutter/src/auth/token_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

/// Test-only TokenStorage backed by an in-memory map.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlatformRepository repository;
  late FakeTokenStorage storage;

  setUp(() {
    repository = FakePlatformRepository();
    storage = FakeTokenStorage();
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
}
