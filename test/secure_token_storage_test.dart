// Tests for SecureTokenStorage default implementation in eden_platform_flutter.
//
// Per TRD 10-03 RESEARCH Pattern 1 (CLI-01): wraps flutter_secure_storage
// with read/write/clear + transparent migration from shared_preferences.
//
// Per RESEARCH Pitfall 1: pinned to flutter_secure_storage 9.2.4 (NOT 10.x —
// upstream issue #1043, data-loss bug in migration).
//
// MethodChannel mocking: this test mocks BOTH `plugins.it_nomads.com/flutter_secure_storage`
// and `plugins.flutter.io/shared_preferences` so flutter_test runs without
// requiring native plugin runtimes.
//
// ignore_for_file: avoid_relative_lib_imports

import 'package:eden_platform_flutter/src/auth/secure_token_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // In-memory backing store for the secure-storage MethodChannel mock. Reset
  // per-test by setUp() so tests don't leak state into each other.
  late Map<String, String> secureStore;
  // Counter for write/read/delete calls so single-flight tests can assert
  // exactly one write happened across N concurrent reads.
  late int writeCallCount;
  late int readCallCount;
  // Optional throw injection for the migration-failure-recovery test.
  Object? throwOnNextWrite;
  // Optional throw injection for the iOS Simulator -25308 retry test.
  // Holds a list of exceptions to throw on consecutive read calls; pop from
  // the front. Empty list = no injection.
  late List<Object> throwOnReadQueue;

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    secureStore = <String, String>{};
    writeCallCount = 0;
    readCallCount = 0;
    throwOnNextWrite = null;
    throwOnReadQueue = <Object>[];
    SharedPreferences.setMockInitialValues(<String, Object>{});

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      switch (call.method) {
        case 'read':
          readCallCount++;
          if (throwOnReadQueue.isNotEmpty) {
            final err = throwOnReadQueue.removeAt(0);
            throw err;
          }
          final key = (call.arguments as Map)['key'] as String;
          return secureStore[key];
        case 'write':
          writeCallCount++;
          if (throwOnNextWrite != null) {
            final err = throwOnNextWrite!;
            throwOnNextWrite = null;
            throw err;
          }
          final key = (call.arguments as Map)['key'] as String;
          final value = (call.arguments as Map)['value'] as String;
          secureStore[key] = value;
          return null;
        case 'delete':
          final key = (call.arguments as Map)['key'] as String;
          secureStore.remove(key);
          return null;
        case 'deleteAll':
          secureStore.clear();
          return null;
        case 'readAll':
          return Map<String, String>.from(secureStore);
        case 'containsKey':
          final key = (call.arguments as Map)['key'] as String;
          return secureStore.containsKey(key);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('SecureTokenStorage round-trip', () {
    test('TestSecureTokenStorage_RoundTrip — write then read returns value',
        () async {
      final storage = SecureTokenStorage();
      await storage.writeAccessToken('jwt-A');
      expect(await storage.readAccessToken(), 'jwt-A');
    });

    test('writeRefreshToken / readRefreshToken round-trip', () async {
      final storage = SecureTokenStorage();
      await storage.writeRefreshToken('refresh-A');
      expect(await storage.readRefreshToken(), 'refresh-A');
    });

    test('writeAccessToken(null) deletes the key', () async {
      final storage = SecureTokenStorage();
      await storage.writeAccessToken('jwt-A');
      await storage.writeAccessToken(null);
      expect(await storage.readAccessToken(), isNull);
    });
  });

  group('SecureTokenStorage migration from shared_preferences', () {
    test(
        'TestSecureTokenStorage_MigratesFromSharedPreferences — read pulls legacy value, writes secure, clears prefs',
        () async {
      // Seed shared_preferences with the legacy value at the package's
      // documented key (StorageKeys.kAccessToken == 'access_token'). The
      // platform-side AuthNotifier wrote this key in releases <=N.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'access_token': 'legacy-jwt',
      });

      final storage = SecureTokenStorage();
      final value = await storage.readAccessToken();

      expect(value, 'legacy-jwt');
      // Migrated to secure storage.
      expect(secureStore['access_token'], 'legacy-jwt');
      // Cleared from shared_preferences.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('access_token'), isNull);
    });

    test('subsequent read returns from secure storage (not prefs)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'access_token': 'legacy-jwt',
      });

      final storage = SecureTokenStorage();
      await storage.readAccessToken(); // triggers migration
      final value = await storage.readAccessToken(); // second call
      expect(value, 'legacy-jwt');
    });

    test('refresh token migrates the same way', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'refresh_token': 'legacy-refresh',
      });

      final storage = SecureTokenStorage();
      final value = await storage.readRefreshToken();

      expect(value, 'legacy-refresh');
      expect(secureStore['refresh_token'], 'legacy-refresh');
    });

    test('migration failure recovery: secure-write throws, prefs untouched',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'access_token': 'legacy-jwt',
      });
      throwOnNextWrite = PlatformException(code: 'simulated-disk-full');

      final storage = SecureTokenStorage();

      // First read attempts migration, secure-write throws. Storage rethrows.
      await expectLater(storage.readAccessToken(), throwsA(isA<PlatformException>()));

      // CRITICAL: shared_preferences MUST still have the value — otherwise
      // the user's session is permanently lost. Write-then-clear order, NOT
      // clear-then-write.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('access_token'), 'legacy-jwt');

      // Retry succeeds because throwOnNextWrite is consumed.
      final retry = await storage.readAccessToken();
      expect(retry, 'legacy-jwt');
      expect(secureStore['access_token'], 'legacy-jwt');
      // Now prefs is cleared.
      expect(prefs.getString('access_token'), isNull);
    });
  });

  group('SecureTokenStorage clear', () {
    test('clear() drops both stores', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'access_token': 'legacy-jwt',
        'refresh_token': 'legacy-refresh',
      });
      final storage = SecureTokenStorage();
      // Migrate first so values land in secure storage.
      await storage.readAccessToken();
      await storage.readRefreshToken();

      await storage.clear();

      expect(secureStore['access_token'], isNull);
      expect(secureStore['refresh_token'], isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('access_token'), isNull);
      expect(prefs.getString('refresh_token'), isNull);
    });

    test('clear() also clears any straggler prefs values (CLI-07 prep)',
        () async {
      // Pretend a prior migration only handled access; refresh is still in prefs.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'refresh_token': 'leftover-refresh',
      });
      final storage = SecureTokenStorage();
      await storage.clear();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('refresh_token'), isNull);
    });
  });

  group('SecureTokenStorage iOS Simulator -25308 retry', () {
    test('retries on -25308 platform exception, then succeeds', () async {
      secureStore['access_token'] = 'jwt-A';
      // First read throws -25308 (iOS Simulator first-launch flake), retry succeeds.
      throwOnReadQueue.add(PlatformException(code: '-25308'));

      final storage = SecureTokenStorage();
      final value = await storage.readAccessToken();
      expect(value, 'jwt-A');
      // Verify retry happened (called twice: failed, then succeeded).
      expect(readCallCount, 2);
    });

    test('rethrows non-25308 PlatformException without retry', () async {
      throwOnReadQueue.add(PlatformException(code: 'OtherError'));

      final storage = SecureTokenStorage();
      await expectLater(
        storage.readAccessToken(),
        throwsA(isA<PlatformException>()),
      );
      expect(readCallCount, 1); // no retry
    });
  });

  group('SecureTokenStorage concurrent migration single-flight', () {
    test('5 concurrent reads during migration result in exactly one secure-write',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'access_token': 'legacy-jwt',
      });

      final storage = SecureTokenStorage();

      // Fire 5 concurrent reads.
      final futures = <Future<String?>>[
        for (var i = 0; i < 5; i++) storage.readAccessToken(),
      ];
      final results = await Future.wait(futures);

      expect(results, equals(<String?>['legacy-jwt', 'legacy-jwt', 'legacy-jwt',
          'legacy-jwt', 'legacy-jwt']));
      // Single-flight: exactly one secure-storage write across 5 concurrent reads.
      expect(writeCallCount, 1);
    });
  });

  test('SecureTokenStorage accepts injected FlutterSecureStorage for testability',
      () async {
    // Constructor takes optional FlutterSecureStorage so consumers can inject
    // mocks. The default value applies AndroidOptions(encryptedSharedPreferences:
    // true) + iOSOptions(accessibility: KeychainAccessibility.first_unlock).
    final injected = const FlutterSecureStorage();
    final storage = SecureTokenStorage(injected);
    await storage.writeAccessToken('jwt-A');
    expect(await storage.readAccessToken(), 'jwt-A');
  });
}
