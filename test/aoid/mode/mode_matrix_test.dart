// THE 3 x 2 REFRESH-TOKEN CUSTODY MATRIX — D4 made mechanical rather than
// documentary.
//
// 50-CONTEXT.md D4 ranks three deployment modes and states that web NEVER holds
// a refresh token. That is prose. This file turns it into an assertion over
// every mode x platform cell, and pins the count: `hasClientHeldRefreshToken`
// is true in EXACTLY ONE of six cells — Mode B on native. Two means a bug;
// zero means Mode B is broken and every "is false" below is vacuous.
//
// WHAT THIS FILE DOES **NOT** PROVE.
//   `kIsWeb` is a compile-time constant and `flutter test` is NEVER web, so
//   nothing here executes in a browser. All six cells are reached through the
//   injected `isWeb` seam that every store/session constructor in this module
//   accepts (default `kIsWeb`), copied from
//   lib/src/networking/connect_cookie_interceptor.dart:55-67, which ships
//   `connectCookieInterceptorWebForTest` for exactly this reason. These tests
//   prove the WEB BRANCH behaves correctly. They do not prove a real browser
//   was exercised. Live-browser coverage is 50-17's.
//
// READING ORDER MATTERS. The positive controls come FIRST. Every "is false" /
// "throws" assertion below would pass vacuously against
// `hasClientHeldRefreshToken => false` or a selector hardcoded to the memory
// store, and the controls are what stop that.
//
// NON-VACUITY OF THE NEGATIVES. Asserting "no refresh token was persisted"
// against a fixture that never had one proves nothing — that mistake has bitten
// this objective three times. So every negative cell below hands a REAL,
// non-empty refresh token to the store it was given and requires the write to
// be REFUSED. The fixture is one where the token WOULD have been persisted if
// the wiring had picked the secure store.
//
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:eden_platform_flutter/src/aoid/aoid_session.dart';
import 'package:eden_platform_flutter/src/aoid/claims/aoid_claims.dart';
import 'package:eden_platform_flutter/src/aoid/mode/aoid_deployment_mode.dart';
import 'package:eden_platform_flutter/src/aoid/storage/aoid_memory_token_store.dart';
import 'package:eden_platform_flutter/src/aoid/storage/aoid_secure_token_store.dart';
import 'package:eden_platform_flutter/src/aoid/storage/aoid_token_store.dart';
import 'package:eden_platform_flutter/src/models/platform_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../claims/fixtures/aoid_claim_fixtures.dart' as claim_fixtures;
import '../riverpod_free_gate_test.dart' show stripComments;
import '../storage/web_never_holds_refresh_token_test.dart'
    show SpyTokenStorage;

/// A refresh token that WOULD be persisted by a secure store. Handed to every
/// negative cell on purpose — see this file's header.
const kRealRefreshToken = 'refresh-token-that-would-have-been-persisted-0001';
const kRealAccessToken = 'access-token-fixture-0001';

/// Any BRANCH on `isWeb` — `if (isWeb)`, `if (!isWeb)`, or the ternary
/// `isWeb ? … : …`.
///
/// The ternary alternative is load-bearing, not thoroughness for its own sake:
/// mutation M2 introduced precisely that form and an earlier version of this
/// pattern — which knew only `if` — did not see it.
final kIsWebBranch = RegExp(r'if\s*\(\s*!?\s*isWeb\s*\)|isWeb\s*\?');

/// The outcome of attempting to wire one matrix cell: either a wiring, or the
/// refusal that prevented one.
class CellOutcome {
  CellOutcome.wired(this.wiring) : refusal = null;
  CellOutcome.refused(this.refusal) : wiring = null;

  final AoidModeWiring? wiring;
  final Object? refusal;

  bool get wasRefused => wiring == null;

  /// A refused cell holds no refresh token — a throw is the strongest possible
  /// "false". Modelled explicitly so item 7 can count over the whole table
  /// without special-casing.
  bool get hasClientHeldRefreshToken =>
      wiring?.hasClientHeldRefreshToken ?? false;
}

/// Attempts to wire one cell, handing in EVERY input a caller could supply —
/// real tokens and a working keychain delegate — so no cell can pass because
/// the wiring had nothing to work with.
CellOutcome wireCell(
  AoidDeploymentMode mode, {
  required bool isWeb,
  required SpyTokenStorage keychain,
}) {
  try {
    return CellOutcome.wired(
      aoidWiringFor(
        mode: mode,
        isWeb: isWeb,
        nativeSecureStorage: keychain,
        accessToken: kRealAccessToken,
        refreshToken: kRealRefreshToken,
      ),
    );
  } catch (e) {
    return CellOutcome.refused(e);
  }
}

/// Every cell of the matrix, built fresh.
List<({AoidDeploymentMode mode, bool isWeb, CellOutcome outcome})>
buildMatrix() {
  final cells =
      <({AoidDeploymentMode mode, bool isWeb, CellOutcome outcome})>[];
  for (final mode in AoidDeploymentMode.values) {
    for (final isWeb in const [true, false]) {
      cells.add((
        mode: mode,
        isWeb: isWeb,
        outcome: wireCell(mode, isWeb: isWeb, keychain: SpyTokenStorage()),
      ));
    }
  }
  return cells;
}

const kFixtureUser = PlatformUser(
  id: 'user-fixture-0001',
  email: 'someone@alpha.test',
  displayName: 'Fixture User',
  isActive: true,
);

void main() {
  group(
    'POSITIVE CONTROLS (run first — the matrix is vacuous without them)',
    () {
      // ITEM 3 — THE ONE TRUE CELL. The positive control for the whole file.
      test('ITEM 3 — Mode B on NATIVE holds the refresh token in the injected '
          'TokenStorage, and reports it', () async {
        final keychain = SpyTokenStorage();

        final wiring = aoidWiringFor(
          mode: AoidDeploymentMode.publicPkce,
          isWeb: false,
          nativeSecureStorage: keychain,
          accessToken: kRealAccessToken,
          refreshToken: kRealRefreshToken,
        );

        expect(
          wiring.hasClientHeldRefreshToken,
          isTrue,
          reason:
              'if this is false the whole matrix is decorative — every other '
              'cell asserts false and would pass against a hardcoded false',
        );
        expect(wiring.session.refreshToken, kRealRefreshToken);
        expect(wiring.isCookieBound, isFalse);
        expect(wiring.session.mode, AoidDeploymentMode.publicPkce);

        // And the store must be the keychain-backed one, actually reaching the
        // injected delegate — not a memory store silently dropping the write.
        expect(wiring.tokenStore, isA<AoidSecureTokenStore>());
        await wiring.tokenStore.writeRefreshToken(kRealRefreshToken);
        expect(await wiring.tokenStore.readRefreshToken(), kRealRefreshToken);
        expect(
          keychain.calls,
          contains('writeRefreshToken($kRealRefreshToken)'),
        );
      });

      // Without this, "the store refused the write" assertions below could pass
      // against a store family that refuses on every platform.
      test(
        'a keychain store DOES persist on native — refusal is not universal',
        () async {
          final keychain = SpyTokenStorage();
          final store = AoidSecureTokenStore(keychain, isWeb: false);
          await store.writeRefreshToken(kRealRefreshToken);
          expect(keychain.values['refresh'], kRealRefreshToken);
        },
      );
    },
  );

  group('THE MATRIX — 3 modes x 2 platforms, custody per cell', () {
    // ITEMS 1, 2, 4, 5, 6 — one test per cell, stated explicitly so a cell that
    // changes meaning has to be edited deliberately rather than absorbed by a
    // blanket matcher.
    for (final mode in AoidDeploymentMode.values) {
      for (final isWeb in const [true, false]) {
        final platform = isWeb ? 'WEB' : 'NATIVE';

        test('$mode on $platform', () async {
          final keychain = SpyTokenStorage();
          final outcome = wireCell(mode, isWeb: isWeb, keychain: keychain);

          if (mode == AoidDeploymentMode.publicPkce && isWeb) {
            // ITEM 4 — Mode B on web is REFUSED, not merely false.
            expect(
              outcome.wasRefused,
              isTrue,
              reason:
                  'Mode B on web is D4\'s forbidden configuration; selection '
                  'must throw, not downgrade',
            );
            expect(outcome.refusal, isA<UnsupportedError>());
            expect(
              (outcome.refusal! as UnsupportedError).message ?? '',
              contains('D4'),
              reason: 'the refusal must send the reader to the decision',
            );
            // And nothing reached the keychain delegate on the way out.
            expect(keychain.calls, isEmpty);
            return;
          }

          expect(
            outcome.wasRefused,
            isFalse,
            reason: 'this cell is a supported configuration',
          );
          final wiring = outcome.wiring!;

          if (mode == AoidDeploymentMode.publicPkce) {
            // Mode B / native — the one true cell, restated in table form.
            expect(wiring.hasClientHeldRefreshToken, isTrue);
            expect(wiring.isCookieBound, isFalse);
            return;
          }

          // ITEMS 1, 2, 5, 6 — Modes A and C, both platforms: cookie-bound,
          // no client-held refresh token, and NOTHING written to any store.
          expect(
            wiring.hasClientHeldRefreshToken,
            isFalse,
            reason: '$mode holds no refresh token on any platform',
          );
          expect(wiring.session.refreshToken, isNull);
          expect(
            wiring.isCookieBound,
            isTrue,
            reason:
                'Modes A and C are cookie-bound — that is what lets them '
                'reuse PlatformSession.cookieBound and AuthNotifier\'s '
                'existing persistence skip',
          );

          // NON-VACUOUS: hand the store a REAL refresh token. If the wiring had
          // picked the secure store, this would have been persisted.
          expect(wiring.tokenStore, isA<AoidMemoryTokenStore>());
          await expectLater(
            wiring.tokenStore.writeRefreshToken(kRealRefreshToken),
            throwsA(isA<UnsupportedError>()),
            reason:
                'the store handed to $mode must be incapable of holding a '
                'refresh token, not merely unused',
          );
          expect(await wiring.tokenStore.readRefreshToken(), isNull);
          expect(
            keychain.calls,
            isEmpty,
            reason:
                'the supplied keychain delegate must be ignored outright for '
                '$mode — it was offered and must not have been taken',
          );
        });
      }
    }
  });

  group('ITEM 7 — the whole-table invariants', () {
    test('EXACTLY ONE cell in the matrix has a client-held refresh token', () {
      final matrix = buildMatrix();

      final holders = matrix
          .where((c) => c.outcome.hasClientHeldRefreshToken)
          .map((c) => '${c.mode.name}/${c.isWeb ? "web" : "native"}')
          .toList();

      expect(
        holders,
        hasLength(1),
        reason:
            'two means a second custody path opened; zero means Mode B on '
            'native is broken and every other cell is vacuous. Holders: '
            '$holders',
      );
      expect(holders.single, 'publicPkce/native');
    });

    test('NO WEB CELL holds a refresh token, in any mode — D4\'s headline', () {
      final matrix = buildMatrix();
      final webHolders = matrix
          .where((c) => c.isWeb && c.outcome.hasClientHeldRefreshToken)
          .toList();
      expect(webHolders, isEmpty);
      // And the table really did cover all three modes on web, so "no holders"
      // is not "no rows".
      expect(matrix.where((c) => c.isWeb).length, 3);
    });

    test('the matrix covers every mode x platform cell — six, not five', () {
      final matrix = buildMatrix();
      expect(matrix, hasLength(6));
      expect(
        matrix.map((c) => '${c.mode.name}/${c.isWeb}').toSet(),
        hasLength(6),
      );
    });

    test('the mode set is exactly the three D4 modes', () {
      expect(AoidDeploymentMode.values, hasLength(3));
      expect(AoidDeploymentMode.values.map((m) => m.name).toSet(), <String>{
        'bff',
        'publicPkce',
        'sameOrigin',
      });
    });

    test('mode -> posture is a BIJECTION onto 50-02\'s three postures — 50-09 '
        'maps onto that vocabulary, it does not replace it', () {
      final postures = AoidDeploymentMode.values.map((m) => m.posture).toSet();
      expect(postures, hasLength(3));
      expect(postures, AoidRefreshTokenPosture.values.toSet());
    });

    // Without this the forward map (AoidDeploymentModeCustody.posture) and the
    // reverse map (AoidSession.mode) are two independent switches that can
    // disagree, and the bijection test above still passes because a SWAPPED
    // map is still a bijection. A consumer calling
    // `aoidTokenStoreFor(posture: mode.posture)` would then get the wrong
    // store. Tie the advertised posture to the one actually produced.
    test('mode.posture equals the posture of the session aoidWiringFor really '
        'builds — the forward and reverse maps cannot disagree', () {
      for (final mode in AoidDeploymentMode.values) {
        final outcome = wireCell(
          mode,
          isWeb: false,
          keychain: SpyTokenStorage(),
        );
        expect(outcome.wasRefused, isFalse, reason: '$mode on native');
        expect(
          outcome.wiring!.session.posture,
          mode.posture,
          reason:
              '$mode advertises posture ${mode.posture} but the wiring built a '
              'session with ${outcome.wiring!.session.posture}',
        );
        // And round-tripping through the reverse map returns the same mode.
        expect(outcome.wiring!.session.mode, mode);
      }
    });

    test('D4\'s ranking is Mode A first, then C, then B', () {
      final ranked = AoidDeploymentMode.values.toList()
        ..sort((a, b) => a.d4Rank.compareTo(b.d4Rank));
      expect(ranked, [
        AoidDeploymentMode.bff,
        AoidDeploymentMode.sameOrigin,
        AoidDeploymentMode.publicPkce,
      ]);
    });

    // `isSelectableOnWeb` is documentation. This is what stops it becoming a
    // comforting lie: it must agree, cell by cell, with what actually happens.
    test('isSelectableOnWeb agrees with the REAL refusal for every mode', () {
      for (final mode in AoidDeploymentMode.values) {
        final outcome = wireCell(
          mode,
          isWeb: true,
          keychain: SpyTokenStorage(),
        );
        expect(
          mode.isSelectableOnWeb,
          !outcome.wasRefused,
          reason:
              'the advertised selectability of $mode on web disagrees with '
              'what aoidWiringFor actually does',
        );
      }
    });
  });

  group('the web refusal has ONE home — 50-02\'s constructor guard', () {
    // The mode package must not carry its own isWeb branch. Two guards drift
    // silently: both still compile when they disagree.
    test('aoid_deployment_mode.dart routes the refusal through '
        'AoidSecureTokenStore rather than re-deciding it', () {
      final source = File(
        'lib/src/aoid/mode/aoid_deployment_mode.dart',
      ).readAsStringSync();
      final code = stripComments(source);

      expect(
        code,
        contains('AoidSecureTokenStore('),
        reason: 'the refusal must be REACHED, not reimplemented',
      );
      expect(
        kIsWebBranch.hasMatch(code),
        isFalse,
        reason:
            'a branch on isWeb here is a SECOND D4 guard. It can drift out of '
            'sync with AoidSecureTokenStore\'s and the drift compiles. Route '
            'the refusal through 50-02 instead. Matched: '
            '${kIsWebBranch.firstMatch(code)?.group(0)}',
      );
    });

    // Positive control for the predicate above: a regex that matches nothing
    // passes forever. Prove it fires on EVERY branching form, not just the one
    // that happened to be written first.
    //
    // The ternary row is not hypothetical. Mutation M2 wrote exactly that form
    // and slipped past an earlier version of this gate that only knew `if`.
    test('POSITIVE CONTROL — the isWeb-branch predicate fires on if, negated '
        'if, and TERNARY forms', () {
      const planted = <String, String>{
        'if': 'AoidTokenStore pick() { if (isWeb) return memory; }',
        'negated if': 'AoidTokenStore pick() { if (!isWeb) return secure; }',
        'ternary': 'final store = isWeb ? memory : secure;',
        'ternary, spaced': 'final store = isWeb   ?  memory : secure;',
      };
      planted.forEach((form, src) {
        expect(
          kIsWebBranch.hasMatch(stripComments(src)),
          isTrue,
          reason: 'the gate is blind to the $form form',
        );
      });
    });

    // And the comment stripper must not be the thing doing the work: a guard
    // mentioned only in prose must NOT satisfy the `contains` assertion above.
    test('POSITIVE CONTROL — stripComments removes prose, so a guard named '
        'only in a comment cannot satisfy the gate', () {
      const prose =
          '// we call AoidSecureTokenStore( somewhere else\nvoid f() {}';
      expect(stripComments(prose), isNot(contains('AoidSecureTokenStore(')));
    });

    test(
      'Mode B on web refuses even though a perfectly good keychain delegate '
      'was supplied — the guard is keyed on the PLATFORM, not on absence',
      () {
        final keychain = SpyTokenStorage()
          ..values['refresh'] = kRealRefreshToken;
        expect(
          () => aoidWiringFor(
            mode: AoidDeploymentMode.publicPkce,
            isWeb: true,
            nativeSecureStorage: keychain,
            accessToken: kRealAccessToken,
            refreshToken: kRealRefreshToken,
          ),
          throwsA(isA<UnsupportedError>()),
        );
      },
    );

    test('Mode B WITHOUT a keychain delegate is a wiring error on both '
        'platforms — never a silent downgrade to a weaker mode', () {
      for (final isWeb in const [true, false]) {
        expect(
          () => aoidWiringFor(
            mode: AoidDeploymentMode.publicPkce,
            isWeb: isWeb,
            accessToken: kRealAccessToken,
            refreshToken: kRealRefreshToken,
          ),
          throwsA(isA<ArgumentError>()),
          reason:
              'isWeb:$isWeb — returning a memory store here would answer a '
              'Mode B request with a Mode A wiring, silently',
        );
      }
    });
  });

  group('Modes A and C reuse PlatformSession.cookieBound — no parallel session '
      'type', () {
    test('a cookie-bound AoidSession becomes a cookieBound PlatformSession, so '
        'AuthNotifier\'s existing persistence skip applies', () {
      for (final mode in const [
        AoidDeploymentMode.bff,
        AoidDeploymentMode.sameOrigin,
      ]) {
        for (final isWeb in const [true, false]) {
          final wiring = aoidWiringFor(
            mode: mode,
            isWeb: isWeb,
            accessToken: kRealAccessToken,
          );
          final platform = wiring.session.toPlatformSession(user: kFixtureUser);

          expect(
            platform.cookieBound,
            isTrue,
            reason:
                '$mode/isWeb:$isWeb must hit the cookieBound constructor — '
                'auth_provider.dart:184-186 keys its _persistTokens skip on '
                'exactly this flag',
          );
          expect(platform.refreshToken, '');
          expect(platform.accessToken, '');
          expect(platform.user.id, kFixtureUser.id);
        }
      }
    });

    // Positive control: the bridge is not hardcoded to cookieBound.
    test('POSITIVE CONTROL — Mode B on native produces a BEARER '
        'PlatformSession carrying the real tokens', () {
      final wiring = aoidWiringFor(
        mode: AoidDeploymentMode.publicPkce,
        isWeb: false,
        nativeSecureStorage: SpyTokenStorage(),
        accessToken: kRealAccessToken,
        refreshToken: kRealRefreshToken,
      );
      final platform = wiring.session.toPlatformSession(user: kFixtureUser);

      expect(platform.cookieBound, isFalse);
      expect(platform.refreshToken, kRealRefreshToken);
      expect(platform.accessToken, kRealAccessToken);
    });

    test('role is NEVER derived from a claim — the portal\'s `role: me.aal` '
        'overload is not institutionalised here', () {
      // NON-VACUOUS FIXTURE. The session carries REAL access claims whose
      // `aal` is a non-null 'aal2'. A bridge that fell back to `role ??
      // accessClaims?.aal` — the portal's overload
      // (aoid_auth_strategy.dart:215-222) — would surface 'aal2' here.
      //
      // An earlier version of this test used a claim-less session, and
      // mutation M6 SURVIVED against it: with no claims, the broken predicate
      // and the correct one both produce null.
      final access = AoidAccessClaims.decodeUnverified(
        claim_fixtures.accessTokenSwitchedToTenantB,
      );
      expect(
        access.aal,
        isNotNull,
        reason: 'the fixture must be one where the overload WOULD be visible',
      );

      final session = AoidSession.backendHeldCookie(
        isWeb: true,
        accessClaims: access,
      );

      expect(
        session.toPlatformSession(user: kFixtureUser).role,
        isNull,
        reason:
            'role must stay null when the app supplied none, even though the '
            'access token carries aal=${access.aal}. An assurance level is '
            'not a role: AOID owns authN, the app owns authZ.',
      );
      expect(
        session.toPlatformSession(user: kFixtureUser, role: 'app-chosen').role,
        'app-chosen',
        reason: 'the role is whatever the consuming app says it is',
      );

      // Same property on the bearer branch, so the fix cannot land on one
      // constructor only.
      final bearer = AoidSession.deviceKeychain(
        accessToken: kRealAccessToken,
        refreshToken: kRealRefreshToken,
        isWeb: false,
        accessClaims: access,
      );
      expect(bearer.toPlatformSession(user: kFixtureUser).role, isNull);
    });
  });

  group(
    'the session carries its claims as FIRST-CLASS FIELDS, not an Expando',
    () {
      test('AoidSession keeps the two claim sets APART (D5) — there is no '
          'unified claims field for the two `tnt` values to meet at', () {
        final source = File(
          'lib/src/aoid/aoid_session.dart',
        ).readAsStringSync();
        final code = stripComments(source);

        expect(
          code,
          isNot(contains('Expando')),
          reason:
              'an Expando side-table is invisible to the type system and dies '
              'with the session object',
        );
        expect(code, contains('AoidAccessClaims? accessClaims'));
        expect(code, contains('AoidIdClaims? idClaims'));
      });

      // NON-VACUOUS: real decoded claims, not nulls. A `null`-only fixture would
      // pass against fields that are hardcoded null or dropped on the floor.
      test('REAL claims handed in are carried back out on every mode, with the '
          'two `tnt` values still APART (D5)', () {
        final access = AoidAccessClaims.decodeUnverified(
          claim_fixtures.accessTokenSwitchedToTenantB,
        );
        final id = AoidIdClaims.decodeUnverified(
          claim_fixtures.idTokenHomeTenant,
        );

        for (final mode in AoidDeploymentMode.values) {
          final wiring = aoidWiringFor(
            mode: mode,
            isWeb: false,
            nativeSecureStorage: SpyTokenStorage(),
            accessToken: kRealAccessToken,
            refreshToken: kRealRefreshToken,
            accessClaims: access,
            idClaims: id,
          );

          expect(wiring.session.accessClaims, same(access), reason: '$mode');
          expect(wiring.session.idClaims, same(id), reason: '$mode');
          expect(wiring.session.mode, mode);

          // The whole reason they are two fields: the ACTIVE tenant slug and the
          // HOME tenant UUID are different values and must stay reachable
          // separately. This fixture pair is one where conflating them WOULD be
          // observable — the user has switched to tenant B.
          // Note the accessors: `.slug` vs `.uuid`. tenant_ref.dart forbids a
          // shared `String get value` on purpose, so these two cannot even be
          // read through a common name, let alone compared by accident.
          expect(
            wiring.session.accessClaims!.activeTenant.slug,
            claim_fixtures.tenantBSlug,
          );
          expect(
            wiring.session.idClaims!.homeTenant.uuid,
            claim_fixtures.homeTenantUuid,
          );
          expect(
            wiring.session.accessClaims!.activeTenant.slug,
            isNot(wiring.session.idClaims!.homeTenant.uuid),
          );
        }
      });
    },
  );
}
