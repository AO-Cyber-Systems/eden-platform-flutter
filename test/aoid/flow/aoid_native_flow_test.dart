// the spec task 3 — AoidNativeFlow, the ceremony state machine.
//
// TEST LIST (written first; RED before GREEN, one at a time).
//
//   1  a full password -> TOTP -> code ceremony drives to a terminal code,
//      exposing next / availableMethods at each step
//   2  the flow ALWAYS presents the latest handle — asserted on the recorded
//      request bodies, never on a successful login
//   3  a REJECTED factor keeps the ceremony alive on the rotated handle and
//      re-prompts the SAME step, carrying no reason
//   4  MaxAttempts exhaustion is a terminal, RECOVERABLE "restart" state, not
//      an exception
//   5  redirect_to_web is a first-class state, not an error
//   6  a transport failure is its own state and does NOT destroy the ceremony
//      (the restoreSession sign-out defect, not repeated)
//   7  the flow never auto-retries — one submission, one verify call
//   8  SOURCE GATE: no member through which app-owned Dart could read back a
//      submitted credential (D3's precondition for the spec sealed widgets),
//      with a POSITIVE CONTROL proving the predicate can fire
//   9  the handle LIFECYCLE on failure paths — added after the fixture was
//      found to consume the handle on a 503, which the server does not do.
//      Each failure mode has a DIFFERENT answer and only the happy path is
//      obvious:
//        503 / write-gate  -> NOT consumed (the service was never reached)
//        wrong factor      -> consumed, rotated, one durable attempt spent
//        expired / replayed-> already refused; the ceremony is over

import 'dart:io';

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../auth/fixtures/fake_aoid_endpoint.dart';

void main() {
  late FakeAoidEndpoint fake;
  late AoidNativeFlow flow;

  setUp(() {
    fake = FakeAoidEndpoint(issuer: kFakeAoidIssuer);
    flow = AoidNativeFlow(
      client: AoidNativeClient(
        endpoints: AoidEndpoints.parse(kFakeAoidIssuer),
        httpClient: fake.client,
      ),
      clientId: kFakeNativeClientId,
      tenantId: kFakeTenantA,
      redirectUri: kFakeRedirectUri,
    );
  });

  Future<void> begin() => flow.begin(codeChallenge: kFakeCodeChallenge);

  List<String> presentedHandles() => fake.nativeRequests
      .where((r) => r.path.endsWith('/verify'))
      .map((r) => r.fields['auth_session']!)
      .toList();

  test(
    '1 a full password -> TOTP -> code ceremony reaches a terminal code',
    () async {
      fake.scriptNativeCeremony([
        const FakeNativeAdvance(
          next: 'mfa',
          availableMethods: ['totp', 'backup_code'],
        ),
        const FakeNativeTerminal('auth-code-fixture'),
      ]);

      await begin();
      final started = flow.state as AoidFlowAwaitingFactor;
      expect(started.next, 'password');
      expect(started.availableMethods, ['password', 'webauthn_discoverable']);
      expect(started.lastAttemptRejected, isFalse);

      await flow.submitPassword(
        email: 'someone@alpha.test',
        password: 'correct horse battery staple',
      );
      final mfa = flow.state as AoidFlowAwaitingFactor;
      expect(mfa.next, 'mfa');
      expect(mfa.availableMethods, ['totp', 'backup_code']);
      expect(mfa.lastAttemptRejected, isFalse);

      await flow.submitOtp('123456');
      expect(
        (flow.state as AoidFlowComplete).authorizationCode,
        'auth-code-fixture',
      );
      expect(flow.authorizationCode, 'auth-code-fixture');
    },
  );

  test(
    '2 the flow always presents the LATEST handle, never the previous one',
    () async {
      fake.scriptNativeCeremony([
        const FakeNativeAdvance(next: 'mfa', availableMethods: ['totp']),
        const FakeNativeTerminal('auth-code-fixture'),
      ]);
      await begin();
      await flow.submitPassword(email: 'someone@alpha.test', password: 'pw');
      await flow.submitOtp('123456');

      final presented = presentedHandles();
      expect(presented, hasLength(2));
      expect(presented.first, kFakeHandle1);
      expect(
        presented.toSet(),
        hasLength(2),
        reason: 'a replayed handle is refused',
      );
      // The second presentation must be the successor the FIRST response minted.
      expect(presented[1], fake.mintedNativeHandles[1]);
    },
  );

  test(
    '3 a rejected factor keeps the ceremony alive and re-prompts the SAME step',
    () async {
      fake.scriptNativeCeremony([
        const FakeNativeReject(),
        const FakeNativeTerminal('auth-code-fixture'),
      ]);
      await begin();
      await flow.submitPassword(email: 'someone@alpha.test', password: 'wrong');

      final again = flow.state as AoidFlowAwaitingFactor;
      expect(again.next, 'password', reason: 'the step is unchanged');
      expect(again.lastAttemptRejected, isTrue);
      // the spec folds unknown-email / wrong-password / no-credential / locked into
      // ONE indistinguishable answer. The flow must expose no more than "that
      // did not work".
      expect(again.availableMethods, isEmpty);

      // And the ceremony is genuinely still usable on the ROTATED handle.
      await flow.submitPassword(email: 'someone@alpha.test', password: 'right');
      expect(flow.state, isA<AoidFlowComplete>());
      final presented = presentedHandles();
      expect(presented[1], isNot(presented[0]));
    },
  );

  test(
    '4 MaxAttempts exhaustion is a recoverable restart state, not a throw',
    () async {
      fake.scriptNativeCeremony([const FakeNativeAttemptCapExceeded()]);
      await begin();
      await flow.submitPassword(email: 'someone@alpha.test', password: 'pw');
      expect(flow.state, isA<AoidFlowRestartRequired>());
    },
  );

  test('5 redirect_to_web is a first-class state, not an error', () async {
    fake.scriptNativeCeremony([const FakeNativeRedirect()]);
    await begin();
    await flow.submitPassword(email: 'someone@alpha.test', password: 'pw');

    final redirect = flow.state as AoidFlowRedirectRequired;
    expect(redirect.result.authorizationUrl, Uri.parse(kFakeAuthorizationUrl));
    // TELEMETRY ONLY — never UI copy.
    expect(redirect.result.reason, 'redirect_to_web');
    expect(flow.state, isNot(isA<AoidFlowFailed>()));
  });

  test(
    '6 a transport failure is its own state and does not end the ceremony',
    () async {
      fake.scriptNativeCeremony([
        const FakeNativeUnavailable(),
        const FakeNativeTerminal('auth-code-fixture'),
      ]);
      await begin();
      await flow.submitPassword(email: 'someone@alpha.test', password: 'pw');

      expect(flow.state, isA<AoidFlowUnavailable>());
      expect(flow.state, isNot(isA<AoidFlowFailed>()));
      expect(flow.state, isNot(isA<AoidFlowRestartRequired>()));
      expect((flow.state as AoidFlowUnavailable).retryAfterSeconds, 30);

      // the spec write gate fires BEFORE the service is called, so the handle was
      // never consumed: the SAME handle must still be presentable.
      await flow.submitPassword(email: 'someone@alpha.test', password: 'pw');
      expect(flow.state, isA<AoidFlowComplete>());
      final presented = presentedHandles();
      expect(presented, [kFakeHandle1, kFakeHandle1]);
    },
  );

  test(
    '7 one submission fires exactly one verify — the flow never auto-retries',
    () async {
      // the spec MaxAttempts is DURABLE and per-handle. A client retry loop burns
      // the successor and destroys a recoverable ceremony.
      fake.scriptNativeCeremony([const FakeNativeReject()]);
      await begin();
      await flow.submitPassword(email: 'someone@alpha.test', password: 'pw');
      expect(presentedHandles(), hasLength(1));
    },
  );

  group('9 the handle LIFECYCLE on failure paths', () {
    // Getting this wrong in either direction is a real defect: a client that
    // discards a still-valid handle strands the user mid-ceremony, and one
    // that reuses a consumed handle is refused with a message that says
    // nothing useful. Each case is pinned separately because they have
    // DIFFERENT answers and only the happy path is obvious.

    test('a 503 write-gate rejection does NOT consume the handle', () async {
      // the spec nativeWriteAllowed runs BEFORE r.nativeLogin.Verify, so the
      // ceremony service never saw the request.
      fake.scriptNativeCeremony([
        const FakeNativeUnavailable(),
        const FakeNativeTerminal('auth-code-fixture'),
      ]);
      await begin();
      await flow.submitPassword(email: 'someone@alpha.test', password: 'pw');
      await flow.submitPassword(email: 'someone@alpha.test', password: 'pw');

      expect(presentedHandles(), [kFakeHandle1, kFakeHandle1]);
      expect(flow.state, isA<AoidFlowComplete>());
      // Nothing was minted beyond the original: no rotation happened.
      expect(fake.mintedNativeHandles, [kFakeHandle1]);
    });

    test(
      'a wrong-factor rejection DOES consume the handle and rotates',
      () async {
        // the spec: Consume burns the presented handle and increments the DURABLE
        // per-handle attempt counter, then Rotate issues a successor carrying
        // the count forward. A wrong password costs one attempt, up to
        // MaxAttempts = 5.
        fake.scriptNativeCeremony([
          const FakeNativeReject(),
          const FakeNativeTerminal('auth-code-fixture'),
        ]);
        await begin();
        await flow.submitPassword(
          email: 'someone@alpha.test',
          password: 'wrong',
        );
        await flow.submitPassword(
          email: 'someone@alpha.test',
          password: 'right',
        );

        final presented = presentedHandles();
        expect(presented.first, kFakeHandle1);
        expect(presented[1], isNot(kFakeHandle1));
        expect(fake.mintedNativeHandles, hasLength(2));
        expect(flow.state, isA<AoidFlowComplete>());
      },
    );

    test(
      'the handle a rejection consumed is REFUSED if presented again',
      () async {
        // The client-side counterpart of the spec mutation 11 (reusing the
        // predecessor collides on the primary key). Drive the transport
        // directly, since the flow structurally cannot present a stale handle.
        final client = AoidNativeClient(
          endpoints: AoidEndpoints.parse(kFakeAoidIssuer),
          httpClient: fake.client,
        );
        fake.scriptNativeCeremony([
          const FakeNativeReject(),
          const FakeNativeTerminal('auth-code-fixture'),
        ]);
        await client.start(
          clientId: kFakeNativeClientId,
          tenantId: kFakeTenantA,
          redirectUri: kFakeRedirectUri,
          codeChallenge: kFakeCodeChallenge,
        );
        await client.verify(
          authSession: kFakeHandle1,
          clientId: kFakeNativeClientId,
          tenantId: kFakeTenantA,
          method: 'password',
        );
        await expectLater(
          client.verify(
            authSession: kFakeHandle1, // the CONSUMED one
            clientId: kFakeNativeClientId,
            tenantId: kFakeTenantA,
            method: 'password',
          ),
          throwsA(
            isA<AoidError>().having(
              (e) => e.code,
              'code',
              AoidErrorCode.invalidSession,
            ),
          ),
        );
      },
    );

    test(
      'an expired handle ends the ceremony and stops further submission',
      () async {
        fake.scriptNativeCeremony([const FakeNativeAdvance(next: 'mfa')]);
        await begin();
        fake.expireNativeCeremony();
        await flow.submitPassword(email: 'someone@alpha.test', password: 'pw');

        expect(flow.state, isA<AoidFlowRestartRequired>());
        expect(flow.canSubmit, isFalse);

        // A further submission must NOT put another request on the wire: the
        // handle is gone, and the spec attempt cap is durable.
        final before = fake.nativeRequests.length;
        await flow.submitOtp('123456');
        expect(fake.nativeRequests.length, before);
        expect(flow.state, isA<AoidFlowRestartRequired>());
      },
    );
  });

  group('8 D3 source gate — no credential read-back', () {
    late String source;

    setUpAll(() {
      source = File(
        'lib/src/aoid/flow/aoid_native_flow.dart',
      ).readAsStringSync();
    });

    // Comments discard first: the file DOCUMENTS the rule, and a whole-file
    // grep cannot tell a doctrine comment from a declaration (the lesson the spec
    // and the spec both recorded).
    String stripComments(String src) => src
        .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
        .replaceAll(RegExp(r'//[^\n]*'), '');

    /// Getters that would hand a credential back to app-owned Dart.
    final credentialGetter = RegExp(
      r'\b(?:String|Object|dynamic)\??\s+get\s+\w*(?:password|credential|secret|otp|passcode)\w*\b',
      caseSensitive: false,
    );

    /// A credential STORED in a field — the first step toward exposing one,
    /// and reachable from a debugger dump even while private.
    final credentialField = RegExp(
      r'\b(?:final\s+)?(?:String|Object|dynamic)\??\s+_?\w*(?:password|credential|secret|passcode)\w*\s*(?:=|;)',
      caseSensitive: false,
    );

    test('the flow declares no credential getter', () {
      final hits = credentialGetter
          .allMatches(stripComments(source))
          .map((m) => m.group(0))
          .toList();
      expect(
        hits,
        isEmpty,
        reason:
            'D3: app-owned Dart must never read the '
            'plaintext back. the spec seals AoidLoginForm on this guarantee.',
      );
    });

    test('the flow stores no credential in a field', () {
      final hits = credentialField
          .allMatches(stripComments(source))
          .map((m) => m.group(0))
          .toList();
      expect(hits, isEmpty);
    });

    test('POSITIVE CONTROL: both predicates fire on a planted violation', () {
      // Without this, either predicate could be silently broken (a bad regex
      // matches nothing and the gate passes forever). Falsify it here.
      const planted = '''
        class Probe {
          String _password = '';
          String get password => _password;
        }
      ''';
      expect(
        credentialGetter.allMatches(stripComments(planted)),
        isNotEmpty,
        reason: 'the getter predicate must be able to fail',
      );
      expect(
        credentialField.allMatches(stripComments(planted)),
        isNotEmpty,
        reason: 'the field predicate must be able to fail',
      );
    });

    test('the file states the D3 rule for the next reader', () {
      expect(source, contains('D3'));
    });
  });
}
