// THE D4 GATE — on web, no AOID code path can persist a refresh token.
//
// This file is not hygiene. 50-CONTEXT.md premise correction C3 records that
// the forbidden configuration was SHIPPING: SecureTokenStorage fell back to
// shared_preferences (localStorage on web) on any secure-storage failure, its
// own comment arguing that was fine "because flutter_secure_storage_web also
// uses localStorage" — which is an argument for removing BOTH paths, not for
// keeping either. AoidOidcAuthStrategy wrote the refresh token through it
// unconditionally, and AoidConfig.fromEnvironment() defaulted AOID login ON
// against the production eden-biz web console. Net: AOID refresh tokens were
// durably readable by any XSS on that console.
//
// D4 (50-CONTEXT.md) ranks the postures and lists "refresh token in web
// localStorage" as forbidden. TRD 50-02 removes the CAPABILITY rather than
// discouraging its use, and this file is what keeps it removed.
//
// WHAT THIS FILE DOES **NOT** PROVE:
//   `kIsWeb` is a compile-time constant and `flutter test` is NEVER web, so
//   nothing here executes on a browser. Coverage comes from the injected
//   `isWeb` seam that every store/session constructor accepts (default
//   `kIsWeb`), copied from lib/src/networking/connect_cookie_interceptor.dart
//   :55-67, which ships `connectCookieInterceptorWebForTest` for exactly this
//   reason. These tests prove the WEB BRANCH behaves correctly, not that a
//   real browser was exercised.
//
// READING ORDER MATTERS. The positive controls come FIRST and deliberately so:
// every "is false" / "is not a secure store" assertion below would pass
// vacuously against a getter hardcoded to `false` or a selector hardcoded to
// return the memory store. The positive controls are what make the negative
// assertions mean something.
//
// ignore_for_file: avoid_relative_lib_imports

import 'package:eden_platform_flutter/src/aoid/aoid_session.dart';
import 'package:eden_platform_flutter/src/aoid/storage/aoid_memory_token_store.dart';
import 'package:eden_platform_flutter/src/aoid/storage/aoid_secure_token_store.dart';
import 'package:eden_platform_flutter/src/aoid/storage/aoid_token_store.dart';
import 'package:eden_platform_flutter/src/aoid/storage/aoid_token_store_selector.dart';
import 'package:eden_platform_flutter/src/auth/token_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hand-built map-backed [TokenStorage] that RECORDS every call, so a test can
/// assert an implementation never reached it.
class SpyTokenStorage implements TokenStorage {
  final List<String> calls = <String>[];
  final Map<String, String?> values = <String, String?>{};

  @override
  Future<String?> readAccessToken() async {
    calls.add('readAccessToken');
    return values['access'];
  }

  @override
  Future<String?> readRefreshToken() async {
    calls.add('readRefreshToken');
    return values['refresh'];
  }

  @override
  Future<void> writeAccessToken(String? value) async {
    calls.add('writeAccessToken($value)');
    values['access'] = value;
  }

  @override
  Future<void> writeRefreshToken(String? value) async {
    calls.add('writeRefreshToken($value)');
    values['refresh'] = value;
  }

  @override
  Future<void> clear() async {
    calls.add('clear');
    values.clear();
  }
}

void main() {
  group('POSITIVE CONTROLS (run first — the negatives are vacuous without '
      'them)', () {
    // Item 10. Without this, item 9's table passes against
    // `bool get hasClientHeldRefreshToken => false;`.
    test(
      'Mode B on NATIVE yields hasClientHeldRefreshToken == TRUE — the getter '
      'is not hardcoded false',
      () {
        final session = AoidSession.deviceKeychain(
          accessToken: 'access-mode-b-native-positive-control',
          refreshToken: 'refresh-mode-b-native-positive-control',
          isWeb: false,
        );

        expect(
          session.hasClientHeldRefreshToken,
          isTrue,
          reason:
              'if this is false the getter is hardcoded and every web '
              'assertion in this file is decorative',
        );
        expect(
          session.refreshToken,
          'refresh-mode-b-native-positive-control',
          reason: 'and it must be the value we handed in, not some default',
        );
      },
    );

    // Companion control for item 11. Without this, item 11 passes against
    // `AoidTokenStore aoidTokenStoreFor(...) => AoidMemoryTokenStore();`.
    test('the selector DOES return a secure store for Mode B on NATIVE — it is '
        'not hardcoded to the memory store', () {
      final store = aoidTokenStoreFor(
        posture: AoidRefreshTokenPosture.deviceKeychain,
        isWeb: false,
        nativeSecureStorage: SpyTokenStorage(),
      );

      expect(
        store,
        isA<AoidSecureTokenStore>(),
        reason:
            'if the selector can never return a secure store, asserting it '
            'does not return one on web proves nothing',
      );
    });

    // Control for the AoidSecureTokenStore constructor guard: it must accept
    // native. A constructor that threw unconditionally would make item 7 pass
    // for the wrong reason.
    test('AoidSecureTokenStore constructs fine on NATIVE', () {
      expect(
        () => AoidSecureTokenStore(SpyTokenStorage(), isWeb: false),
        returnsNormally,
      );
    });
  });

  group('D4 — AoidSecureTokenStore refuses to exist on web', () {
    // Item 7 — the failure is CONSTRUCTION, not the first write. A wiring-time
    // failure surfaces in a test; a first-write failure surfaces in production.
    test('constructing with isWeb:true throws UnsupportedError', () {
      expect(
        () => AoidSecureTokenStore(SpyTokenStorage(), isWeb: true),
        throwsA(isA<UnsupportedError>()),
        reason:
            'the object must be impossible to build on web, not merely '
            'impossible to write through',
      );
    });

    test(
      'the constructor throws BEFORE touching the delegate — no call reaches '
      'the keychain/localStorage backend',
      () {
        final spy = SpyTokenStorage();
        expect(
          () => AoidSecureTokenStore(spy, isWeb: true),
          throwsA(isA<UnsupportedError>()),
        );
        expect(spy.calls, isEmpty);
      },
    );

    // Item 8 — assert the VALUE of the message, so the reader is sent to the
    // decision rather than left with a bare type.
    test('the thrown message names D4 and "refresh token"', () {
      Object? caught;
      try {
        AoidSecureTokenStore(SpyTokenStorage(), isWeb: true);
      } catch (e) {
        caught = e;
      }

      expect(caught, isA<UnsupportedError>());
      final message = (caught! as UnsupportedError).message ?? '';
      expect(message, contains('D4'));
      expect(message, contains('refresh token'));
      // And it must point at the remedy, not just the prohibition.
      expect(message, contains('AoidMemoryTokenStore'));
    });
  });

  group('D4 — no web session holds a client-held refresh token', () {
    // Item 9, table-driven over EVERY posture. Each row states the expectation
    // explicitly rather than relying on a single blanket matcher, so a row
    // that changes meaning has to be edited deliberately.
    //
    // Mode B on web is STRONGER than "the getter is false": the session cannot
    // be constructed at all. That is the D4 posture — structurally impossible,
    // not merely discouraged.
    for (final posture in AoidRefreshTokenPosture.values) {
      test('posture $posture on WEB cannot yield a client-held refresh '
          'token', () {
        switch (posture) {
          case AoidRefreshTokenPosture.deviceKeychain:
            // Handed a REAL non-empty refresh token, on purpose: if the guard
            // were keyed on the token being absent rather than on isWeb, this
            // row would pass for the wrong reason.
            expect(
              () => AoidSession.deviceKeychain(
                accessToken: 'access-mode-b-web-attempt',
                refreshToken: 'refresh-mode-b-web-attempt',
                isWeb: true,
              ),
              throwsA(isA<UnsupportedError>()),
              reason: 'Mode B is native-only (D4) — it must not construct',
            );

          case AoidRefreshTokenPosture.backendHeldCookie:
            final session = AoidSession.backendHeldCookie(
              accessToken: 'access-mode-a-web',
              isWeb: true,
            );
            expect(session.hasClientHeldRefreshToken, isFalse);
            expect(session.refreshToken, isNull);

          case AoidRefreshTokenPosture.none:
            final session = AoidSession.sameOriginCookie(isWeb: true);
            expect(session.hasClientHeldRefreshToken, isFalse);
            expect(session.refreshToken, isNull);
        }
      });
    }

    // Exhaustiveness guard: if a later TRD (50-09 owns the full mode matrix)
    // adds a fourth posture, the loop above covers it automatically and the
    // switch stops being exhaustive at compile time. This asserts the set we
    // believe we are covering, so a silent widening is caught here too.
    test('the posture set is exactly the three D4 modes', () {
      expect(AoidRefreshTokenPosture.values, hasLength(3));
      expect(
        AoidRefreshTokenPosture.values.map((p) => p.name).toSet(),
        <String>{'backendHeldCookie', 'deviceKeychain', 'none'},
      );
    });

    test('Mode B on web names D4 in its refusal', () {
      Object? caught;
      try {
        AoidSession.deviceKeychain(
          accessToken: 'access-mode-b-web-message',
          refreshToken: 'refresh-mode-b-web-message',
          isWeb: true,
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<UnsupportedError>());
      expect((caught! as UnsupportedError).message ?? '', contains('D4'));
    });
  });

  group('D4 — the store selector never hands web a persisting store', () {
    // Item 11, over EVERY posture, and with a secure delegate supplied so the
    // selector has every opportunity to pick the wrong thing.
    for (final posture in AoidRefreshTokenPosture.values) {
      test('posture $posture with isWeb:true selects AoidMemoryTokenStore', () {
        final spy = SpyTokenStorage();
        final store = aoidTokenStoreFor(
          posture: posture,
          isWeb: true,
          nativeSecureStorage: spy,
        );

        expect(store, isA<AoidMemoryTokenStore>());
        expect(store, isNot(isA<AoidSecureTokenStore>()));
        // The supplied secure delegate must be ignored outright on web.
        expect(spy.calls, isEmpty);
      });
    }

    test('and the store it hands back REFUSES a refresh write — the end-to-end '
        'property, not just the type', () async {
      final store = aoidTokenStoreFor(
        posture: AoidRefreshTokenPosture.backendHeldCookie,
        isWeb: true,
        nativeSecureStorage: SpyTokenStorage(),
      );

      await expectLater(
        store.writeRefreshToken('refresh-token-selector-web'),
        throwsA(isA<UnsupportedError>()),
      );
      expect(await store.readRefreshToken(), isNull);
    });

    test('native Mode A / Mode C also get the memory store (cookie-bound)', () {
      for (final posture in <AoidRefreshTokenPosture>[
        AoidRefreshTokenPosture.backendHeldCookie,
        AoidRefreshTokenPosture.none,
      ]) {
        expect(
          aoidTokenStoreFor(
            posture: posture,
            isWeb: false,
            nativeSecureStorage: SpyTokenStorage(),
          ),
          isA<AoidMemoryTokenStore>(),
          reason: 'posture $posture holds no refresh token on any platform',
        );
      }
    });

    test('Mode B on native without a secure delegate is a wiring error, not a '
        'silent downgrade to the memory store', () {
      expect(
        () => aoidTokenStoreFor(
          posture: AoidRefreshTokenPosture.deviceKeychain,
          isWeb: false,
        ),
        throwsA(isA<ArgumentError>()),
        reason:
            'silently returning a memory store here would produce a native '
            'session that mysteriously fails to restore',
      );
    });
  });
}
