// The discoverable-passkey ceremony in AoidNativeFlow.
//
// The server path (AOID internal/nativelogin/stages.go):
//
//   started          -> password, webauthn_discoverable_challenge
//   webauthn_pending -> webauthn, webauthn_discoverable
//
// There is NO edge from webauthn_pending back to password, so a passkey
// attempt that does not complete must start a fresh ceremony.
//
// TEST LIST (written first; RED before GREEN, one at a time). Every value is a
// hand-written literal.
//
//   1  canUsePasskey after begin: true when start advertises
//      webauthn_discoverable, false when it does not
//   2  canUsePasskey survives a REJECTED password; a password that ADVANCES
//      (mfa) ends it
//   3  signInWithPasskey before begin -> unavailable, zero requests
//   4  the challenge request: method=webauthn_discoverable_challenge, the
//      current handle, NO factor field
//   5  the authenticator receives IDENTICAL() the publicKey map the transport
//      decoded
//   6  BYTE IDENTITY: webauthn_response on the wire == the authenticator's
//      string; method=webauthn_discoverable; completed; the scripted code
//   7  cancelled -> cancelled + ONE fresh /start with the SAME begin args;
//      password usable, canUsePasskey true again
//   8  notAssociated / unsupported -> unavailable, failed -> failed (+ one
//      restart each)
//   9  AOID rejects the assertion -> rejected + one restart
//  10  the challenge answered 503 -> interrupted, NO restart, the handle
//      survived
//  11  the challenge answered invalid_session -> interrupted, RestartRequired,
//      no automatic restart
//  12  a challenge without publicKey -> failed, authenticator NOT called, one
//      restart (12b: no webauthn_challenge at all — same answer)
//  13  a restart that itself gets 503 -> interrupted, AoidFlowUnavailable
//  14  NO RETRY: every test from 4 to 13 pins the exact /verify and /start
//      counts
//  16  AoidPasskeyOutcome is public; the authenticator interface is not
//
// (Item 15, the assertion source gate, lives in aoid_native_flow_test.dart
// group 8.)

import 'dart:io';

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:eden_platform_flutter/src/aoid/passkey/aoid_passkey_authenticator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../auth/fixtures/fake_aoid_endpoint.dart';
import '../source_utils.dart';

/// Begin arguments, all non-default, so a restart that dropped any one of them
/// is visible on the wire.
const List<String> _scopes = ['openid', 'email', 'offline_access'];
const String _nonce = 'n-0S6_WzA2Mj-nonce';
const String _activeTenantSlug = 'acme-alpha';
const String _loginHint = 'someone@alpha.test';

/// A discoverable challenge in the shape AOID's
/// `BeginDiscoverableMediatedLogin` emits.
const String _challengeJson =
    '{"publicKey":{"challenge":"q2Xv-7kd_R0aZ9mPq3sT1uVwX8yZ0aB2cD4eF6gH8iI",'
    '"timeout":300000,"rpId":"auth.fake-aoid.test","allowCredentials":[],'
    '"userVerification":"preferred"},"mediation":"conditional"}';

/// A WebAuthn assertion as the platform half assembles it: base64url fields
/// carrying `-` and `_`, nested JSON, no padding — and ONE space after the last
/// colon, on purpose: a compact literal survives `jsonEncode(jsonDecode(x))`
/// unchanged, so without it a flow that re-encoded the assertion would still
/// pass item 6.
const String _assertionJson =
    '{"id":"cR3d-Ent_1d-alpha","rawId":"cR3d-Ent_1d-alpha",'
    '"type":"public-key","authenticatorAttachment":"platform",'
    '"response":{"clientDataJSON":"eyJ0eXBlIjoid2ViYXV0aG4uZ2V0In0-_Q2xp",'
    '"authenticatorData":"SZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2M-BQ",'
    '"signature":"MEUCIQD-_c2lnbmF0dXJlLWFscGhh_AiB-zz",'
    '"userHandle":"dXNlci1oYW5kbGUtYWxwaGE"},"clientExtensionResults": {}}';

/// Records the map it was handed and answers a scripted attempt.
final class _FakeAuthenticator implements AoidPasskeyAuthenticator {
  _FakeAuthenticator(this._attempt, {this.onGetAssertion});

  final AoidPasskeyAttempt _attempt;

  /// Runs at the moment the flow asks for an assertion — lets a test capture
  /// `flow.state` while the challenge is live.
  final void Function()? onGetAssertion;

  final List<Map<String, dynamic>> received = [];

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<AoidPasskeyAttempt> getAssertion(
    Map<String, dynamic> publicKey,
  ) async {
    onGetAssertion?.call();
    received.add(publicKey);
    return _attempt;
  }
}

void main() {
  late FakeAoidEndpoint fake;
  late AoidNativeFlow flow;

  AoidNativeFlow flowOver(http.Client client) => AoidNativeFlow(
    client: AoidNativeClient(
      endpoints: AoidEndpoints.parse(kFakeAoidIssuer),
      httpClient: client,
    ),
    clientId: kFakeNativeClientId,
    tenantId: kFakeTenantA,
    redirectUri: kFakeRedirectUri,
  );

  setUp(() {
    fake = FakeAoidEndpoint(issuer: kFakeAoidIssuer);
    flow = flowOver(fake.client);
  });

  Future<void> begin([AoidNativeFlow? on]) => (on ?? flow).begin(
    codeChallenge: kFakeCodeChallenge,
    scopes: _scopes,
    nonce: _nonce,
    activeTenant: const AoidActiveTenantSlug(_activeTenantSlug),
    loginHint: _loginHint,
  );

  List<RecordedNativeRequest> starts() => fake.nativeRequests
      .where((r) => r.path.endsWith('/oauth/native/start'))
      .toList();

  List<RecordedNativeRequest> verifies() => fake.nativeRequests
      .where((r) => r.path.endsWith('/oauth/native/verify'))
      .toList();

  group('1-2 canUsePasskey', () {
    test(
      '1a true after a start that advertises webauthn_discoverable',
      () async {
        await begin();
        expect(flow.canUsePasskey, isTrue);
      },
    );

    test('1b false after a start that does not advertise it', () async {
      fake.startAvailableMethods = const ['password'];
      await begin();
      expect(flow.canUsePasskey, isFalse);
    });

    test('2a SURVIVES a rejected password (same-stage rotation)', () async {
      // The rejection reply carries no available_methods — "advertised" must
      // come from the START reply, not from the current state.
      fake.scriptNativeCeremony([const FakeNativeReject()]);
      await begin();
      await flow.submitPassword(email: 'someone@alpha.test', password: 'nope');

      final again = flow.state as AoidFlowAwaitingFactor;
      expect(again.lastAttemptRejected, isTrue);
      expect(again.availableMethods, isEmpty);
      expect(flow.canUsePasskey, isTrue);
    });

    test('2b ENDS when a password advances the ceremony to MFA', () async {
      fake.scriptNativeCeremony([
        const FakeNativeAdvance(next: 'mfa', availableMethods: ['totp']),
      ]);
      await begin();
      await flow.submitPassword(email: 'someone@alpha.test', password: 'pw');

      expect((flow.state as AoidFlowAwaitingFactor).next, 'mfa');
      expect(flow.canSubmit, isTrue);
      expect(flow.canUsePasskey, isFalse);
    });
  });

  test(
    '3 signInWithPasskey before begin: unavailable, zero requests',
    () async {
      final authenticator = _FakeAuthenticator(
        const AoidPasskeyAsserted(_assertionJson),
      );

      final outcome = await flow.signInWithPasskey(authenticator);

      expect(outcome, AoidPasskeyOutcome.unavailable);
      expect(fake.nativeRequests, isEmpty);
      expect(authenticator.received, isEmpty);
      expect(flow.state, isA<AoidFlowIdle>());
    },
  );

  group('4-6 the ceremony', () {
    // ONE scripted reply per /verify; a restart is a /start, which is never
    // scripted. Item 14 is asserted in every test as exact request counts.
    const challengeStep = FakeNativeAdvance(
      next: 'webauthn',
      webauthnChallenge: _challengeJson,
    );

    test('4 the challenge request carries the method, the CURRENT handle and '
        'no factor field', () async {
      fake.scriptNativeCeremony([
        challengeStep,
        const FakeNativeTerminal('code-passkey-alpha'),
      ]);
      await begin();

      await flow.signInWithPasskey(
        _FakeAuthenticator(const AoidPasskeyAsserted(_assertionJson)),
      );

      final challenge = verifies().first.fields;
      expect(challenge['method'], 'webauthn_discoverable_challenge');
      expect(challenge['auth_session'], kFakeHandle1);
      for (final factorField in const [
        'password',
        'email',
        'otp',
        'webauthn_response',
      ]) {
        expect(challenge, isNot(contains(factorField)), reason: factorField);
      }
      // 14: challenge + assertion, nothing else.
      expect(verifies(), hasLength(2));
      expect(starts(), hasLength(1));
    });

    test('5 the authenticator receives IDENTICAL() the publicKey map the '
        'transport decoded', () async {
      fake.scriptNativeCeremony([
        challengeStep,
        const FakeNativeTerminal('code-passkey-alpha'),
      ]);
      await begin();
      AoidFlowState? whileAsserting;
      final authenticator = _FakeAuthenticator(
        const AoidPasskeyAsserted(_assertionJson),
        onGetAssertion: () => whileAsserting = flow.state,
      );

      await flow.signInWithPasskey(authenticator);

      final live = whileAsserting as AoidFlowAwaitingFactor;
      expect(live.next, 'webauthn');
      final decoded = live.webauthnChallenge!['publicKey'];
      final received = authenticator.received.single;
      expect(
        identical(received, decoded),
        isTrue,
        reason: 'no copy, no re-encode: the instance the transport decoded',
      );
      expect(received, {
        'challenge': 'q2Xv-7kd_R0aZ9mPq3sT1uVwX8yZ0aB2cD4eF6gH8iI',
        'timeout': 300000,
        'rpId': 'auth.fake-aoid.test',
        'allowCredentials': <Object?>[],
        'userVerification': 'preferred',
      });
      expect(verifies(), hasLength(2));
      expect(starts(), hasLength(1));
    });

    test('6 BYTE IDENTITY: webauthn_response on the wire is the '
        "authenticator's string", () async {
      fake.scriptNativeCeremony([
        challengeStep,
        const FakeNativeTerminal('code-passkey-alpha'),
      ]);
      await begin();

      final outcome = await flow.signInWithPasskey(
        _FakeAuthenticator(const AoidPasskeyAsserted(_assertionJson)),
      );

      expect(outcome, AoidPasskeyOutcome.completed);
      expect(flow.state, isA<AoidFlowComplete>());
      expect(flow.authorizationCode, 'code-passkey-alpha');

      final assertion = verifies()[1];
      expect(assertion.fields['method'], 'webauthn_discoverable');
      // Presented on the handle the CHALLENGE reply minted.
      expect(assertion.fields['auth_session'], fake.mintedNativeHandles[1]);
      // Decoded form field: equal to the literal, character for character.
      expect(assertion.fields['webauthn_response'], _assertionJson);
      // And on the wire: the raw form body carries exactly the form-encoding
      // of the literal — nothing was re-serialised on the way.
      expect(
        assertion.rawBody,
        contains(
          'webauthn_response=${Uri.encodeQueryComponent(_assertionJson)}',
        ),
      );
      expect(verifies(), hasLength(2));
      expect(starts(), hasLength(1));
    });
  });

  group('7-9 an attempt that does not complete restarts the ceremony ONCE', () {
    // AOID has no webauthn_pending -> password edge, so without a restart the
    // password field would be dead after a cancelled sheet.
    const challengeStep = FakeNativeAdvance(
      next: 'webauthn',
      webauthnChallenge: _challengeJson,
    );

    /// The restart is ONE new /start replaying the original begin arguments.
    void expectOneFaithfulRestart() {
      final s = starts();
      expect(s, hasLength(2), reason: 'exactly one restart');
      final original = s[0].fields;
      final restart = s[1].fields;
      expect(restart['code_challenge'], kFakeCodeChallenge);
      expect(restart['scope'], 'openid email offline_access');
      expect(restart['nonce'], _nonce);
      expect(restart['tenant'], _activeTenantSlug);
      expect(restart['login_hint'], _loginHint);
      // And nothing else drifted either.
      expect(restart, original);
    }

    /// After a restart the form is usable: password step, NOT flagged as a
    /// rejected attempt, on the fresh handle, and the passkey offer is back.
    void expectUsableForm() {
      final again = flow.state as AoidFlowAwaitingFactor;
      expect(again.next, 'password');
      expect(again.lastAttemptRejected, isFalse);
      expect(flow.canSubmit, isTrue);
      expect(flow.canUsePasskey, isTrue);
    }

    test('7 cancelled -> cancelled, one restart with the SAME begin args, '
        'the password usable', () async {
      fake.scriptNativeCeremony([
        challengeStep,
        const FakeNativeTerminal('code-password-alpha'),
      ]);
      await begin();

      final outcome = await flow.signInWithPasskey(
        _FakeAuthenticator(
          const AoidPasskeyNotAsserted(AoidPasskeyFailure.cancelled),
        ),
      );

      expect(outcome, AoidPasskeyOutcome.cancelled);
      expectOneFaithfulRestart();
      expectUsableForm();
      expect(verifies(), hasLength(1), reason: '14: the challenge only');

      // The password genuinely works on the restarted ceremony's handle.
      await flow.submitPassword(email: _loginHint, password: 'right');
      expect(flow.state, isA<AoidFlowComplete>());
      expect(verifies()[1].fields['auth_session'], fake.mintedNativeHandles[2]);
    });

    for (final (failure, expected) in const [
      (AoidPasskeyFailure.notAssociated, AoidPasskeyOutcome.unavailable),
      (AoidPasskeyFailure.unsupported, AoidPasskeyOutcome.unavailable),
      (AoidPasskeyFailure.failed, AoidPasskeyOutcome.failed),
    ]) {
      test('8 ${failure.name} -> ${expected.name}, one restart', () async {
        fake.scriptNativeCeremony([challengeStep]);
        await begin();

        final outcome = await flow.signInWithPasskey(
          _FakeAuthenticator(AoidPasskeyNotAsserted(failure)),
        );

        expect(outcome, expected);
        expectOneFaithfulRestart();
        expectUsableForm();
        expect(verifies(), hasLength(1), reason: '14: the challenge only');
      });
    }

    test('9 AOID rejects the assertion -> rejected, one restart, the password '
        'usable', () async {
      fake.scriptNativeCeremony([
        challengeStep,
        const FakeNativeReject(),
        const FakeNativeTerminal('code-password-alpha'),
      ]);
      await begin();

      final outcome = await flow.signInWithPasskey(
        _FakeAuthenticator(const AoidPasskeyAsserted(_assertionJson)),
      );

      expect(outcome, AoidPasskeyOutcome.rejected);
      expectOneFaithfulRestart();
      expectUsableForm();
      expect(verifies(), hasLength(2), reason: '14: challenge + assertion');

      await flow.submitPassword(email: _loginHint, password: 'right');
      expect(flow.state, isA<AoidFlowComplete>());
      expect(verifies(), hasLength(3));
    });

    test('12 a challenge without publicKey -> failed, authenticator NOT '
        'called, one restart', () async {
      fake.scriptNativeCeremony([
        const FakeNativeAdvance(
          next: 'webauthn',
          webauthnChallenge: '{"mediation":"conditional"}',
        ),
      ]);
      await begin();
      final authenticator = _FakeAuthenticator(
        const AoidPasskeyAsserted(_assertionJson),
      );

      final outcome = await flow.signInWithPasskey(authenticator);

      expect(outcome, AoidPasskeyOutcome.failed);
      expect(authenticator.received, isEmpty);
      expectOneFaithfulRestart();
      expectUsableForm();
      expect(verifies(), hasLength(1), reason: '14: the challenge only');
    });

    test('12b next=webauthn with NO webauthn_challenge at all -> failed, one '
        'restart (the ceremony is at webauthn_pending either way)', () async {
      fake.scriptNativeCeremony([const FakeNativeAdvance(next: 'webauthn')]);
      await begin();
      final authenticator = _FakeAuthenticator(
        const AoidPasskeyAsserted(_assertionJson),
      );

      final outcome = await flow.signInWithPasskey(authenticator);

      expect(outcome, AoidPasskeyOutcome.failed);
      expect(authenticator.received, isEmpty);
      expectOneFaithfulRestart();
      expectUsableForm();
      expect(verifies(), hasLength(1), reason: '14: the challenge only');
    });
  });

  group('10-11 interrupted: the state already says why, and NO restart', () {
    test('10 a 503 on the challenge -> interrupted, no restart, the handle '
        'survived', () async {
      fake.scriptNativeCeremony([
        const FakeNativeUnavailable(),
        const FakeNativeTerminal('code-password-alpha'),
      ]);
      await begin();
      final authenticator = _FakeAuthenticator(
        const AoidPasskeyAsserted(_assertionJson),
      );

      final outcome = await flow.signInWithPasskey(authenticator);

      expect(outcome, AoidPasskeyOutcome.interrupted);
      expect(flow.state, isA<AoidFlowUnavailable>());
      expect((flow.state as AoidFlowUnavailable).retryAfterSeconds, 30);
      expect(authenticator.received, isEmpty);
      expect(starts(), hasLength(1), reason: 'a restart would burn the handle');
      expect(verifies(), hasLength(1), reason: '14: the challenge only');
      // The replica refused BEFORE the service ran, so AOID is still at
      // `started`: the user may try either factor again.
      expect(flow.canUsePasskey, isTrue);

      // The SAME handle is presented by the next user action.
      await flow.submitPassword(email: _loginHint, password: 'right');
      expect(flow.state, isA<AoidFlowComplete>());
      expect(verifies().map((r) => r.fields['auth_session']), [
        kFakeHandle1,
        kFakeHandle1,
      ]);
      expect(starts(), hasLength(1));
    });

    test('11 invalid_session on the challenge (attempt cap) -> interrupted, '
        'RestartRequired, no automatic restart', () async {
      fake.scriptNativeCeremony([const FakeNativeAttemptCapExceeded()]);
      await begin();

      final outcome = await flow.signInWithPasskey(
        _FakeAuthenticator(const AoidPasskeyAsserted(_assertionJson)),
      );

      expect(outcome, AoidPasskeyOutcome.interrupted);
      expect(flow.state, isA<AoidFlowRestartRequired>());
      expect(flow.canUsePasskey, isFalse);
      expect(starts(), hasLength(1));
      expect(verifies(), hasLength(1), reason: '14: the challenge only');
    });

    test('13 a RESTART that itself gets 503 -> interrupted (not cancelled), '
        'AoidFlowUnavailable, and it is not retried', () async {
      // The fake scripts /verify only, so the 503 on the SECOND /start is
      // injected here. Every other request passes through to the fake
      // untouched (MockClient hands the handler a finalized request, so it is
      // copied before being re-sent).
      final refusedStarts = <http.Request>[];
      var startsSeen = 0;
      final wrapped = MockClient((request) async {
        if (request.url.path.endsWith('/oauth/native/start') &&
            ++startsSeen == 2) {
          refusedStarts.add(request);
          return http.Response(
            '{"error":"temporarily_unavailable",'
            '"error_description":"this region cannot accept writes"}',
            503,
            headers: {'content-type': 'application/json', 'retry-after': '45'},
          );
        }
        final copy = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;
        return http.Response.fromStream(await fake.client.send(copy));
      });
      final restartFails = flowOver(wrapped);
      fake.scriptNativeCeremony([
        const FakeNativeAdvance(
          next: 'webauthn',
          webauthnChallenge: _challengeJson,
        ),
      ]);
      await begin(restartFails);

      final outcome = await restartFails.signInWithPasskey(
        _FakeAuthenticator(
          const AoidPasskeyNotAsserted(AoidPasskeyFailure.cancelled),
        ),
      );

      expect(outcome, AoidPasskeyOutcome.interrupted);
      final state = restartFails.state as AoidFlowUnavailable;
      expect(state.kind, AoidTransportFailureKind.unavailable);
      expect(state.retryAfterSeconds, 45);
      expect(restartFails.canUsePasskey, isFalse);
      // 14: one original start reached the fake, ONE restart was attempted
      // (and refused), and nothing retried it.
      expect(starts(), hasLength(1));
      expect(refusedStarts, hasLength(1));
      expect(startsSeen, 2);
      expect(
        Uri.splitQueryString(refusedStarts.single.body)['code_challenge'],
        kFakeCodeChallenge,
      );
      expect(verifies(), hasLength(1), reason: '14: the challenge only');
    });
  });

  group('16 surface: the outcome is public, the authenticator is not', () {
    const barrel = 'lib/src/aoid/parts/native.dart';

    test('AoidPasskeyOutcome resolves through eden_platform.dart', () {
      // COMPILE-LEVEL: this file imports the public barrel and, from src/,
      // ONLY the authenticator interface file — which does not declare the
      // outcome. If the barrel stopped exporting it, this file would not
      // compile.
      expect(AoidPasskeyOutcome.values.map((v) => v.name), [
        'completed',
        'rejected',
        'cancelled',
        'unavailable',
        'failed',
        'interrupted',
      ]);
    });

    test('the native part-barrel exports the outcome and nothing under '
        'passkey/', () {
      final exports = _exportTargets(
        stripComments(File(barrel).readAsStringSync()),
      );
      expect(exports, contains('../flow/aoid_passkey_outcome.dart'));
      expect(exports.where(_namesPasskeyDir), isEmpty);
    });

    test(
      'POSITIVE CONTROL: the passkey/ predicate fires on a planted export',
      () {
        const planted = '''
        library;
        export '../flow/aoid_native_flow.dart';
        export "../passkey/aoid_passkey_authenticator.dart" show AoidPasskeyAuthenticator;
        export 'package:eden_platform_flutter/src/aoid/passkey/aoid_passkey_resolver.dart';
        import '../passkey/aoid_passkey_authenticator.dart';
      ''';
        // Two exports name passkey/; the IMPORT and the flow export do not.
        expect(_exportTargets(planted).where(_namesPasskeyDir), hasLength(2));
      },
    );
  });
}

/// The URI of every `export` directive in [src].
List<String> _exportTargets(String src) => [
  for (final m in RegExp(
    r'''^\s*export\s+['"]([^'"]+)['"]''',
    multiLine: true,
  ).allMatches(src))
    m.group(1)!,
];

/// Whether an export URI names a file in lib/src/aoid/passkey/.
bool _namesPasskeyDir(String uri) =>
    uri.startsWith('../passkey/') ||
    uri.contains('/src/aoid/passkey/') ||
    uri.startsWith('passkey/');
