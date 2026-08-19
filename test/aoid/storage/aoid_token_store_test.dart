// AoidTokenStore contract tests — the two implementations, in isolation.
//
// WHY AN INJECTED `isWeb` SEAM AND NOT `kIsWeb`:
//   `kIsWeb` is a COMPILE-TIME constant and `flutter test` is never web, so a
//   `kIsWeb`-gated branch is unreachable from this suite. Every store and
//   session here therefore takes `bool isWeb` defaulting to `kIsWeb`, and the
//   tests drive it explicitly. This is the same seam
//   lib/src/networking/connect_cookie_interceptor.dart:55-67 already ships
//   (`connectCookieInterceptorWebForTest`, which exists verbatim "so the web
//   branch can be exercised even on a non-web test platform").
//   DO NOT read these passes as "verified on a real browser" — they verify the
//   branch, not the platform.
//
// Fixtures are hand-written literals (no_llm_test_data is in force for the spec
// the spec): every token string below is spelled out here.
//
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:eden_platform_flutter/src/aoid/aoid_session.dart';
import 'package:eden_platform_flutter/src/aoid/storage/aoid_memory_token_store.dart';
import 'package:eden_platform_flutter/src/aoid/storage/aoid_secure_token_store.dart';
import 'package:eden_platform_flutter/src/aoid/storage/aoid_token_store.dart';
import 'package:eden_platform_flutter/src/auth/token_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hand-built map-backed [TokenStorage]. Stands in for the device keychain so
/// AoidSecureTokenStore's delegation can be observed without a plugin runtime.
class RecordingTokenStorage implements TokenStorage {
  final Map<String, String?> values = <String, String?>{};
  int clearCallCount = 0;

  @override
  Future<String?> readAccessToken() async => values['access'];

  @override
  Future<String?> readRefreshToken() async => values['refresh'];

  @override
  Future<void> writeAccessToken(String? value) async {
    values['access'] = value;
  }

  @override
  Future<void> writeRefreshToken(String? value) async {
    values['refresh'] = value;
  }

  @override
  Future<void> clear() async {
    clearCallCount++;
    values.clear();
  }
}

/// Matches a leading `import`/`export` directive and captures its URI.
/// Anchored at line start so a package named in `//` prose is never mistaken
/// for a real dependency — this file's own headers name
/// `flutter_secure_storage` repeatedly while depending on none of it.
final _directiveRe = RegExp(
  '''^\\s*(?:import|export)\\s+[\\'"]([^\\'"]+)[\\'"]''',
  multiLine: true,
);

/// Every third-party `package:` URI reachable from [root] by following
/// first-party (relative / `package:eden_platform_flutter/`) directives.
Set<String> reachablePackages(String root, {String libDir = 'lib'}) {
  final packages = <String>{};
  final visited = <String>{};
  final queue = <String>[root];

  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    if (!visited.add(File(current).absolute.path)) continue;
    final file = File(current);
    if (!file.existsSync()) continue;

    for (final m in _directiveRe.allMatches(file.readAsStringSync())) {
      final uri = m.group(1)!;
      if (uri.startsWith('dart:')) continue;
      if (uri.startsWith('package:eden_platform_flutter/')) {
        queue.add(
          '$libDir/${uri.substring('package:eden_platform_flutter/'.length)}',
        );
        continue;
      }
      if (uri.startsWith('package:')) {
        packages.add(uri.split('/').first); // `package:name`
        continue;
      }
      queue.add(File(current).parent.uri.resolve(uri).toFilePath());
    }
  }
  return packages;
}

void main() {
  group('AoidMemoryTokenStore', () {
    // Item 1
    test('round-trips an access token in memory', () async {
      final store = AoidMemoryTokenStore();
      expect(await store.readAccessToken(), isNull);

      await store.writeAccessToken('access-token-item-1');
      expect(await store.readAccessToken(), 'access-token-item-1');
    });

    // Item 2 — the loud failure. A silent drop is the anti-pattern this
    // deliberately avoids (it looks like a session-restore bug and invites the
    // next engineer to re-add the write).
    test('writeRefreshToken(non-null) THROWS UnsupportedError, and the message '
        'states the prohibition and names Mode A', () async {
      final store = AoidMemoryTokenStore();

      await expectLater(
        store.writeRefreshToken('refresh-token-item-2'),
        throwsA(isA<UnsupportedError>()),
      );

      // Assert on the VALUE of the message, not merely on the type — a bare
      // "throws" tells the next reader nothing about where to go.
      Object? caught;
      try {
        await store.writeRefreshToken('refresh-token-item-2');
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      final message = (caught! as UnsupportedError).message ?? '';
      expect(message, contains('never held by a web client'));
      expect(message, contains('Mode A'));
    });

    // Item 3 — clearing must always be legal, or logout breaks.
    test('writeRefreshToken(null) is a no-op, NOT a throw', () async {
      final store = AoidMemoryTokenStore();
      await expectLater(store.writeRefreshToken(null), completes);
      expect(await store.readRefreshToken(), isNull);
    });

    // Item 4
    test('readRefreshToken() always returns null', () async {
      final store = AoidMemoryTokenStore();
      expect(await store.readRefreshToken(), isNull);

      // Even after every legal write path has been exercised.
      await store.writeAccessToken('access-token-item-4');
      await store.writeRefreshToken(null);
      expect(await store.readRefreshToken(), isNull);
    });

    // Item 5
    test('clear() drops the access token', () async {
      final store = AoidMemoryTokenStore();
      await store.writeAccessToken('access-token-item-5');
      expect(await store.readAccessToken(), 'access-token-item-5');

      await store.clear();
      expect(await store.readAccessToken(), isNull);
    });

    test('writeAccessToken(null) drops the access token', () async {
      final store = AoidMemoryTokenStore();
      await store.writeAccessToken('access-token-null-case');
      await store.writeAccessToken(null);
      expect(await store.readAccessToken(), isNull);
    });

    test('is an AoidTokenStore', () {
      expect(AoidMemoryTokenStore(), isA<AoidTokenStore>());
    });
  });

  group('AoidSecureTokenStore (native)', () {
    // Item 6
    test(
      'isWeb:false round-trips BOTH tokens through the injected TokenStorage',
      () async {
        final delegate = RecordingTokenStorage();
        final store = AoidSecureTokenStore(delegate, isWeb: false);

        await store.writeAccessToken('access-token-item-6');
        await store.writeRefreshToken('refresh-token-item-6');

        // Read back through the store...
        expect(await store.readAccessToken(), 'access-token-item-6');
        expect(await store.readRefreshToken(), 'refresh-token-item-6');
        //...and confirm the values genuinely landed in the delegate rather
        // than being cached in the store itself.
        expect(delegate.values['access'], 'access-token-item-6');
        expect(delegate.values['refresh'], 'refresh-token-item-6');
      },
    );

    test('clear() delegates to the injected TokenStorage', () async {
      final delegate = RecordingTokenStorage();
      final store = AoidSecureTokenStore(delegate, isWeb: false);
      await store.writeRefreshToken('refresh-token-clear-case');

      await store.clear();

      expect(delegate.clearCallCount, 1);
      expect(delegate.values, isEmpty);
      expect(await store.readRefreshToken(), isNull);
    });

    test('writeRefreshToken(null) delegates a delete on native', () async {
      final delegate = RecordingTokenStorage();
      final store = AoidSecureTokenStore(delegate, isWeb: false);
      await store.writeRefreshToken('refresh-token-delete-case');

      await store.writeRefreshToken(null);

      expect(delegate.values['refresh'], isNull);
    });

    test('is an AoidTokenStore', () {
      expect(
        AoidSecureTokenStore(RecordingTokenStorage(), isWeb: false),
        isA<AoidTokenStore>(),
      );
    });
  });

  group('AoidSession — native postures', () {
    test('deviceKeychain on native carries the refresh token it was given', () {
      final session = AoidSession.deviceKeychain(
        accessToken: 'access-native-session',
        refreshToken: 'refresh-native-session',
        isWeb: false,
      );

      expect(session.posture, AoidRefreshTokenPosture.deviceKeychain);
      expect(session.refreshToken, 'refresh-native-session');
      expect(session.hasClientHeldRefreshToken, isTrue);
    });

    test('backendHeldCookie has no refresh token even on native', () {
      final session = AoidSession.backendHeldCookie(
        accessToken: 'access-mode-a-native',
        isWeb: false,
      );

      expect(session.posture, AoidRefreshTokenPosture.backendHeldCookie);
      expect(session.refreshToken, isNull);
      expect(session.hasClientHeldRefreshToken, isFalse);
    });

    test('sameOriginCookie carries neither token', () {
      final session = AoidSession.sameOriginCookie(isWeb: false);

      expect(session.posture, AoidRefreshTokenPosture.none);
      expect(session.accessToken, isNull);
      expect(session.refreshToken, isNull);
      expect(session.hasClientHeldRefreshToken, isFalse);
    });
  });

  // the spec <verify> block specifies
  //   grep -c "flutter_secure_storage" lib/src/aoid/storage/*.dart -> 0
  // which cannot do this job in EITHER direction:
  //   - it is a raw substring count, so the header comments in
  //     aoid_token_store.dart and aoid_secure_token_store.dart that EXPLAIN
  //     why the module avoids the package trip it. The remedy would be to
  //     delete the explanation — strictly worse code;
  //   - and it only looks at one directory, so a file under lib/src/aoid/
  //     reaching flutter_secure_storage through `../auth/…` passes it. That is
  //     the exact hole the spec found in the equivalent riverpod grep.
  // The closure walk below is the real invariant. It is scoped to this the spec's
  // part-barrel so it does not touch a file another wave-2 the spec owns.
  group('dependency footprint (the pin conflict this design sidesteps)', () {
    const root = 'lib/src/aoid/parts/storage.dart';

    // POSITIVE CONTROL FIRST — an "assert absent" test is vacuous if the
    // walker silently reaches nothing.
    test('POSITIVE CONTROL: the walker sees packages that ARE depended on', () {
      final packages = reachablePackages(root);
      expect(
        packages,
        contains('package:flutter'),
        reason:
            'the storage part-barrel reaches package:flutter (kIsWeb); if '
            'this is missing the walker visited nothing and every absence '
            'assertion below is decorative',
      );
    });

    test('POSITIVE CONTROL: the walker follows FIRST-PARTY hops, not just the '
        'root file', () {
      // aoid_secure_token_store.dart imports../../auth/token_storage.dart,
      // two hops from the barrel. Proving the walk crosses that boundary is
      // what makes the absence assertion meaningful.
      final direct = reachablePackages(
        'lib/src/aoid/storage/aoid_secure_token_store.dart',
      );
      expect(direct, contains('package:flutter'));

      final viaBarrel = reachablePackages(root);
      expect(
        viaBarrel,
        containsAll(direct),
        reason: 'the barrel walk must subsume its members',
      );
    });

    test('nothing reachable from the AOID storage barrel imports '
        'flutter_secure_storage', () {
      final packages = reachablePackages(root);
      expect(
        packages,
        isNot(contains('package:flutter_secure_storage')),
        reason:
            'eden pins flutter_secure_storage to 9.2.4 EXACTLY ("DO NOT bump '
            'to 10.x, upstream #1043 data-loss") while AODex overrides to '
            '^10.0.0. The module depends on the TokenStorage interface so the '
            'two pins never have to be reconciled. Reached: $packages',
      );
    });

    test('nor shared_preferences — the localStorage backing D4 forbids', () {
      expect(
        reachablePackages(root),
        isNot(contains('package:shared_preferences')),
      );
    });
  });
}
