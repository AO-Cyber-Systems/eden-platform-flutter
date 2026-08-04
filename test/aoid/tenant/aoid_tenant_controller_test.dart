// TRD 50-13, task 2 — AoidTenantController.
//
// TEST LIST (written first; RED before GREEN, one at a time).
//
//   3   switchTo exposes `switching == true` while in flight, so the UI can
//       disable the control
//   4   a successful switch decodes the NEW ACCESS token and asserts
//       claims.activeTenant equals the requested slug — the only place the
//       client learns the switch took effect
//   5   onTenantChanged fires EXACTLY ONCE on success, carrying the new slug
//       and no credential
//   5b  ORDERING: onTenantChanged fires AFTER replaceSession. Inverted, the
//       app invalidates its caches and immediately refills them using the OLD
//       access token — the cross-tenant residue this hook exists to prevent
//   6   the switch shares the single-flight slot: a concurrent switch and
//       proactive refresh produce ONE /oauth/token call, not two. Asserted on
//       the CALL COUNT — a state-only assertion passes even when two calls
//       raced and one happened to win
//   6b  the REVERSE ordering: a switch arriving during an in-flight ordinary
//       refresh is NOT swallowed by it. It queues and runs its own call, so
//       the switch always actually happens; two SEQUENTIAL rotations are safe,
//       two CONCURRENT ones are the sign-out
//   7   replaceSession is called with the new pair on success (Mode B) and is
//       NOT called in Modes A/C, where the cookie is swapped server-side —
//       without the caller branching
//   8   a transport failure mid-switch leaves the session intact and
//       `switching` back to false
//
// RESIDUE / SIGN-OUT (the shape this TRD is named after). A→B alone cannot
// prove these; the RETURN LEG is where a `==`-filtered update or a cached
// belief bites:
//   R1  A -> B -> A: the return leg is NOT suppressed. activeTenant ends at A,
//       onTenantChanged fired three times in order [A, B, A], and the listener
//       count matches. riverpod-3 migration checklist item 3 — `state = const
//       XState()` does not notify when already at that sentinel, because const
//       canonicalization makes it the identical object. The remedy is
//       `updateShouldNotify`, NOT de-consting; here it is structural, because
//       ChangeNotifier.notifyListeners() applies no `==` filter at all.
//   R2  re-selecting the CURRENT tenant still round-trips and still notifies.
//       A `if (target == _active) return;` short-circuit would look like an
//       optimisation and would silently skip the cache invalidation the app
//       asked for — the client's belief is a decoded UNVERIFIED hint, not
//       authority.
//   R3  A -> (denied B) -> A: a denial leaves activeTenant at A, does NOT fire
//       onTenantChanged (no false invalidation), and a later permitted switch
//       still works.
//   R4  a switch whose response does NOT carry the requested tenant is
//       REFUSED — but the rotated pair is still PERSISTED. Dropping it would
//       leave the client holding a refresh token the server has already
//       rotated away, which signs the user out on the next refresh. Persist
//       first, verify second.
//
// Fixtures are INLINE and HAND-BUILT (no_llm_test_data), reusing TRD 50-03's
// JWT assembly so the decoded claims are trustworthy.

import 'dart:async';
import 'dart:convert';

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../claims/fixtures/aoid_claim_fixtures.dart';

const _issuer = 'https://auth.fake-aoid.test';
const _clientId = 'aodex-flutter';
const _outsiderSlug = 'initech';

/// A third membership, so A -> B -> A is not the only reachable path.
const _tenantCSlug = 'stark';

// ---------------------------------------------------------------------------
// A counting fake of aoid /oauth/token. Item 6 asserts on `calls`, which is
// why this exists rather than a hand-rolled backend double: the property under
// test is HOW MANY TIMES THE NETWORK WAS HIT.
// ---------------------------------------------------------------------------
class _CountingTokenEndpoint {
  _CountingTokenEndpoint({required this.memberOf});

  final Set<String> memberOf;

  /// Every POST to /oauth/token, in order.
  final List<Map<String, String>> calls = [];

  String liveRefreshToken = 'refresh-token-0001';
  int _seq = 1;

  /// Gate a response until the test releases it, so two operations can be made
  /// genuinely concurrent rather than merely interleaved.
  Completer<void>? gate;

  /// Force the NEXT grant to answer with a token for [lieWithSlug] instead of
  /// the requested tenant — the server-said-no-but-answered-200 case (R4).
  String? lieWithSlug;

  /// Make the next call fail at the socket.
  bool failNextWithSocketError = false;

  http.Response _invalidGrant() => http.Response(
    jsonEncode({
      'error': 'invalid_grant',
      'error_description': 'invalid or expired refresh token',
    }),
    400,
    headers: const {'content-type': 'application/json'},
  );

  http.Client get client => MockClient((request) async {
    final fields = Uri.splitQueryString(request.body);
    calls.add(fields);

    if (failNextWithSocketError) {
      failNextWithSocketError = false;
      throw http.ClientException('fixture: simulated socket failure');
    }

    final held = gate;
    if (held != null) await held.future;

    if (fields['refresh_token'] != liveRefreshToken) return _invalidGrant();

    final target = fields['active_tenant'];
    if (target != null && !memberOf.contains(target)) {
      // Non-consuming: the refresh token stays live.
      return _invalidGrant();
    }

    _seq += 1;
    liveRefreshToken = 'refresh-token-${_seq.toString().padLeft(4, '0')}';

    final lie = lieWithSlug;
    lieWithSlug = null;
    final tnt = lie ?? target ?? homeTenantSlug;

    return http.Response(
      jsonEncode({
        'access_token': buildJwt({
          'iss': _issuer,
          'sub': identitySubject,
          'aud': _clientId,
          'exp': expEpochSeconds,
          'iat': iatEpochSeconds,
          'tnt': tnt,
          'scope': 'openid',
          'client_id': _clientId,
        }),
        'refresh_token': liveRefreshToken,
        'id_token': idTokenHomeTenant,
        'token_type': 'Bearer',
        'expires_in': 900,
      }),
      200,
      headers: const {'content-type': 'application/json'},
    );
  });
}

/// Records every `replaceSession` the controller performs.
class _SessionRecorder {
  final List<({String accessToken, String refreshToken})> replaced = [];

  Future<void> replaceSession({
    required String accessToken,
    required String refreshToken,
  }) async {
    replaced.add((accessToken: accessToken, refreshToken: refreshToken));
  }
}

({
  AoidTenantController controller,
  _CountingTokenEndpoint fake,
  _SessionRecorder session,
  List<AoidActiveTenantSlug> changed,
  List<String> notifications,
})
_modeB({Set<String>? memberOf, AoidActiveTenantSlug? initial}) {
  final fake = _CountingTokenEndpoint(
    memberOf: memberOf ?? {homeTenantSlug, tenantBSlug, _tenantCSlug},
  );
  final session = _SessionRecorder();
  final changed = <AoidActiveTenantSlug>[];
  final notifications = <String>[];
  final controller = AoidTenantController(
    backend: AoidRefreshGrantBackend(
      tokenClient: AoidTokenClient(
        endpoints: AoidEndpoints.parse(_issuer),
        httpClient: fake.client,
        clientId: _clientId,
      ),
      readRefreshToken: () async => fake.liveRefreshToken,
    ),
    replaceSession: session.replaceSession,
    onTenantChanged: changed.add,
    activeTenant: initial ?? const AoidActiveTenantSlug(homeTenantSlug),
  );
  controller.addListener(() {
    notifications.add(
      '${controller.switching}:${controller.activeTenant?.slug}',
    );
  });
  return (
    controller: controller,
    fake: fake,
    session: session,
    changed: changed,
    notifications: notifications,
  );
}

void main() {
  group('the switch', () {
    test(
      'item 3 — switching is true while in flight and false afterwards',
      () async {
        final h = _modeB();
        final gate = Completer<void>();
        h.fake.gate = gate;

        expect(h.controller.switching, isFalse);
        final pending = h.controller.switchTo(
          const AoidActiveTenantSlug(tenantBSlug),
        );
        expect(
          h.controller.switching,
          isTrue,
          reason: 'the UI must be able to disable the control',
        );
        gate.complete();
        await pending;
        expect(h.controller.switching, isFalse);
        // The flag change is observable, not merely readable.
        expect(h.notifications.first, startsWith('true:'));
        expect(h.notifications.last, startsWith('false:'));
      },
    );

    test(
      'item 4 — a successful switch decodes the NEW ACCESS token and confirms '
      'the requested slug landed',
      () async {
        final h = _modeB();
        final landed = await h.controller.switchTo(
          const AoidActiveTenantSlug(tenantBSlug),
        );
        expect(landed.slug, tenantBSlug);
        expect(h.controller.activeTenant?.slug, tenantBSlug);
        // Confirmed against the token the server actually minted, not against
        // what was asked for.
        final minted = h.session.replaced.single.accessToken;
        expect(
          AoidAccessClaims.decodeUnverified(minted).activeTenant.slug,
          tenantBSlug,
        );
      },
    );

    test(
      'item 5 — onTenantChanged fires exactly once, carrying the slug and no '
      'credential',
      () async {
        final h = _modeB();
        await h.controller.switchTo(const AoidActiveTenantSlug(tenantBSlug));
        expect(h.changed, hasLength(1));
        expect(h.changed.single.slug, tenantBSlug);
        // A slug is not a credential (D3). Prove nothing token-shaped rides
        // along: the payload is an extension type over String, so the ONLY
        // thing it can carry is the slug itself.
        expect(h.changed.single.slug, isNot(contains('.')));
      },
    );

    test(
      'item 5b ORDERING — onTenantChanged fires AFTER replaceSession, so the '
      'app cannot refill its caches from the OLD access token',
      () async {
        final order = <String>[];
        final fake = _CountingTokenEndpoint(
          memberOf: {homeTenantSlug, tenantBSlug},
        );
        final controller = AoidTenantController(
          backend: AoidRefreshGrantBackend(
            tokenClient: AoidTokenClient(
              endpoints: AoidEndpoints.parse(_issuer),
              httpClient: fake.client,
              clientId: _clientId,
            ),
            readRefreshToken: () async => fake.liveRefreshToken,
          ),
          replaceSession:
              ({required accessToken, required refreshToken}) async {
                order.add('replaceSession');
              },
          onTenantChanged: (_) => order.add('onTenantChanged'),
          activeTenant: const AoidActiveTenantSlug(homeTenantSlug),
        );
        await controller.switchTo(const AoidActiveTenantSlug(tenantBSlug));
        expect(order, ['replaceSession', 'onTenantChanged']);
      },
    );

    test(
      'item 8 — a transport failure mid-switch leaves the session intact and '
      'switching back to false',
      () async {
        final h = _modeB();
        h.fake.failNextWithSocketError = true;
        await expectLater(
          h.controller.switchTo(const AoidActiveTenantSlug(tenantBSlug)),
          throwsA(isA<AoidTransportError>()),
        );
        expect(h.controller.switching, isFalse);
        expect(h.controller.activeTenant?.slug, homeTenantSlug);
        expect(h.session.replaced, isEmpty);
        expect(h.changed, isEmpty);
      },
    );
  });

  group('the single-flight slot', () {
    test('item 6 — a concurrent switch and proactive refresh produce ONE '
        '/oauth/token call, not two', () async {
      final h = _modeB();
      final gate = Completer<void>();
      h.fake.gate = gate;

      final switching = h.controller.switchTo(
        const AoidActiveTenantSlug(tenantBSlug),
      );
      // Wire this exactly as ProactiveRefresh does: its `restoreSession`
      // callback is controller.refreshSession, so both callers land in the
      // SAME slot object rather than two that cannot collapse.
      final refreshing = h.controller.refreshSession();

      gate.complete();
      await Future.wait([switching, refreshing]);

      expect(
        h.fake.calls,
        hasLength(1),
        reason:
            'two concurrent rotations rotate the refresh token out from '
            'under each other and sign the user out. The CALL COUNT is the '
            'assertion — final state alone passes on a race.',
      );
      expect(h.fake.calls.single['active_tenant'], tenantBSlug);
      expect(h.controller.activeTenant?.slug, tenantBSlug);
    });

    test('item 6b — a switch arriving during an in-flight refresh is NOT '
        'swallowed by it: it queues and still happens', () async {
      final h = _modeB();
      final gate = Completer<void>();
      h.fake.gate = gate;

      final refreshing = h.controller.refreshSession();
      await Future<void>.delayed(Duration.zero);
      final switching = h.controller.switchTo(
        const AoidActiveTenantSlug(tenantBSlug),
      );

      gate.complete();
      h.fake.gate = null;
      await Future.wait([refreshing, switching]);

      // Two SEQUENTIAL rotations, which is safe. Attaching the switch to the
      // refresh would have produced one call and a switch that silently
      // never happened.
      expect(h.fake.calls, hasLength(2));
      expect(h.fake.calls.first.containsKey('active_tenant'), isFalse);
      expect(h.fake.calls.last['active_tenant'], tenantBSlug);
      expect(h.controller.activeTenant?.slug, tenantBSlug);
    });

    test(
      'item 6c — a REAL ProactiveRefresh collapses onto the switch: the slot '
      'is shared IN FACT, not merely by convention',
      () async {
        final h = _modeB();
        // The wiring this module documents, built for real rather than
        // simulated. ProactiveRefresh's `restoreSession` seam IS the
        // composition point, so both callers land in the controller's slot.
        //
        // Without this test "shares the single-flight slot" would rest on a
        // doc comment. Two slots that do not collapse rotate the refresh token
        // twice, and the second rotation invalidates the first — the user is
        // signed out by the very mechanism meant to keep them signed in.
        final proactive = ProactiveRefresh(
          // Expiring in 30s, inside ProactiveRefresh's default 2-minute
          // threshold, so refreshIfNeeded actually fires instead of no-opping.
          getAccessToken: () => buildJwt({
            'exp':
                DateTime.now()
                    .toUtc()
                    .add(const Duration(seconds: 30))
                    .millisecondsSinceEpoch ~/
                1000,
          }),
          restoreSession: h.controller.refreshSession,
        );

        final gate = Completer<void>();
        h.fake.gate = gate;

        final switching = h.controller.switchTo(
          const AoidActiveTenantSlug(tenantBSlug),
        );
        final refreshing = proactive.refreshIfNeeded();

        gate.complete();
        await Future.wait([switching, refreshing]);

        expect(
          h.fake.calls,
          hasLength(1),
          reason:
              'ProactiveRefresh must not mint a second rotation while a '
              'switch is in flight',
        );
        expect(h.fake.calls.single['active_tenant'], tenantBSlug);
        expect(h.controller.activeTenant?.slug, tenantBSlug);
      },
    );
  });

  group('modes A and C — the caller does not branch', () {
    test('item 7 — replaceSession is NOT called when the cookie is swapped '
        'server-side, and the switch still completes', () async {
      final session = _SessionRecorder();
      final changed = <AoidActiveTenantSlug>[];
      var bffCalls = 0;
      final controller = AoidTenantController(
        backend: AoidCookieSwitchBackend(
          mode: AoidDeploymentMode.bff,
          performSwitch: (target) async {
            bffCalls += 1;
            // The app's backend rotated its own cookie and handed back the
            // new access token for claim reading. No refresh token exists
            // client-side in this mode, by design (D4).
            return AoidTenantSwitchOutcome(
              accessToken: buildJwt({
                'iss': _issuer,
                'sub': identitySubject,
                'exp': expEpochSeconds,
                'client_id': _clientId,
                'tnt': target.slug,
              }),
            );
          },
          performRefresh: () async => const AoidTenantSwitchOutcome(),
        ),
        replaceSession: session.replaceSession,
        onTenantChanged: changed.add,
        activeTenant: const AoidActiveTenantSlug(homeTenantSlug),
      );

      // IDENTICAL call site to Mode B — that is item 7's point.
      final landed = await controller.switchTo(
        const AoidActiveTenantSlug(tenantBSlug),
      );

      expect(landed.slug, tenantBSlug);
      expect(bffCalls, 1);
      expect(
        session.replaced,
        isEmpty,
        reason:
            'the client holds no token pair in Modes A/C; persisting the '
            'empty strings would clobber real values',
      );
      expect(changed.single.slug, tenantBSlug);
      expect(controller.activeTenant?.slug, tenantBSlug);
    });

    test(
      'item 7b — Mode C carries no access token at all, so there is nothing to '
      'verify against, and the switch is still reported honestly',
      () async {
        final changed = <AoidActiveTenantSlug>[];
        final controller = AoidTenantController(
          backend: AoidCookieSwitchBackend(
            mode: AoidDeploymentMode.sameOrigin,
            performSwitch: (_) async => const AoidTenantSwitchOutcome(),
            performRefresh: () async => const AoidTenantSwitchOutcome(),
          ),
          onTenantChanged: changed.add,
          activeTenant: const AoidActiveTenantSlug(homeTenantSlug),
        );
        final landed = await controller.switchTo(
          const AoidActiveTenantSlug(tenantBSlug),
        );
        expect(landed.slug, tenantBSlug);
        expect(changed.single.slug, tenantBSlug);
        expect(
          controller.lastSwitchVerified,
          isFalse,
          reason:
              'no access token means the switch was NOT confirmed against '
              'a claim — say so rather than implying it was',
        );
      },
    );
  });

  group('RESIDUE — the sign-out bug this TRD is named after', () {
    test('R1 — A -> B -> A: the RETURN LEG is not suppressed. Three switches, '
        'three notifications, and the belief ends where it started', () async {
      final h = _modeB();

      await h.controller.switchTo(const AoidActiveTenantSlug(homeTenantSlug));
      await h.controller.switchTo(const AoidActiveTenantSlug(tenantBSlug));
      await h.controller.switchTo(const AoidActiveTenantSlug(homeTenantSlug));

      expect(
        h.changed.map((s) => s.slug).toList(),
        [homeTenantSlug, tenantBSlug, homeTenantSlug],
        reason:
            'the third switch RETURNS to a value already seen. That is '
            'exactly where a ==-filtered update drops the notification and '
            'leaves the previous tenant resident (riverpod-3 checklist '
            'item 3) — and the drop is invisible in an A->B-only test.',
      );
      expect(h.controller.activeTenant?.slug, homeTenantSlug);
      expect(h.fake.calls, hasLength(3));
      // Every leg was confirmed against the token the server minted.
      expect(
        h.session.replaced
            .map(
              (r) => AoidAccessClaims.decodeUnverified(
                r.accessToken,
              ).activeTenant.slug,
            )
            .toList(),
        [homeTenantSlug, tenantBSlug, homeTenantSlug],
      );
    });

    test('R2 — re-selecting the CURRENT tenant still round-trips and still '
        'notifies: there is no == short-circuit', () async {
      final h = _modeB(initial: const AoidActiveTenantSlug(tenantBSlug));
      await h.controller.switchTo(const AoidActiveTenantSlug(tenantBSlug));
      expect(
        h.fake.calls,
        hasLength(1),
        reason:
            'the client belief is a decoded UNVERIFIED hint, never '
            'authority — a short-circuit would skip the server round trip',
      );
      expect(
        h.changed,
        hasLength(1),
        reason:
            'the app asked for an invalidation; silently skipping it is '
            'the cross-tenant residue shape',
      );
    });

    test('R3 — A -> (denied B) -> A: a denial leaves the belief at A, fires NO '
        'invalidation, and does not poison a later permitted switch', () async {
      final h = _modeB(memberOf: {homeTenantSlug, tenantBSlug});

      await expectLater(
        h.controller.switchTo(const AoidActiveTenantSlug(_outsiderSlug)),
        throwsA(isA<AoidTenantDenied>()),
      );

      expect(h.controller.activeTenant?.slug, homeTenantSlug);
      expect(h.controller.switching, isFalse);
      expect(
        h.changed,
        isEmpty,
        reason:
            'a denial must not fire a cache invalidation for a tenant '
            'the user never entered',
      );
      expect(h.session.replaced, isEmpty);

      // The refresh token was NOT burned, so the session is still usable.
      final landed = await h.controller.switchTo(
        const AoidActiveTenantSlug(tenantBSlug),
      );
      expect(landed.slug, tenantBSlug);
      expect(h.changed.single.slug, tenantBSlug);
    });

    test(
      'R4 — a switch the server did not apply is REFUSED, but the rotated pair '
      'is still PERSISTED: dropping it would sign the user out',
      () async {
        final h = _modeB();
        // 200, a valid token pair — but tnt is still home. The switch did not
        // take effect and the server did not say so.
        h.fake.lieWithSlug = homeTenantSlug;

        await expectLater(
          h.controller.switchTo(const AoidActiveTenantSlug(tenantBSlug)),
          throwsA(isA<AoidTransportError>()),
        );

        expect(
          h.controller.activeTenant?.slug,
          homeTenantSlug,
          reason:
              'the belief must not move optimistically to an unconfirmed '
              'tenant — that IS the residue',
        );
        expect(h.changed, isEmpty);
        expect(
          h.session.replaced,
          hasLength(1),
          reason:
              'the server ALREADY rotated the refresh token. Discarding '
              'the new pair because verification failed leaves the client '
              'holding a dead token — a sign-out by a different route. '
              'Persist first, verify second.',
        );
        expect(h.controller.switching, isFalse);
      },
    );
  });
}
