// TRD 52-03 — the discoverable-passkey ceremony in AoidNativeFlow.
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
// (Item 15, the D3 source gate, lives in aoid_native_flow_test.dart group 8.)

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../../auth/fixtures/fake_aoid_endpoint.dart';

/// Begin arguments, all non-default, so a restart that dropped any one of them
/// is visible on the wire.
const List<String> _scopes = ['openid', 'email', 'offline_access'];
const String _nonce = 'n-0S6_WzA2Mj-nonce';
const String _activeTenantSlug = 'acme-alpha';
const String _loginHint = 'someone@alpha.test';

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
}
