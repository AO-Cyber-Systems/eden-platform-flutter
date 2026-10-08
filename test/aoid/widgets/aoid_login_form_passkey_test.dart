// TRD 52-04 — "Sign in with a passkey" INSIDE the sealed AoidLoginForm.
//
// The button is part of the seal (52-CONTEXT locked decision 1): no
// constructor parameter, no callback, and the widget never sees the assertion.
// It calls `controller.signInWithPasskey(resolveAoidPasskeyAuthenticator())`
// and renders from the closed `AoidPasskeyOutcome` it gets back, plus the
// flow's state.
//
// The authenticator is a hand-written fake installed through
// `debugAoidPasskeyAuthenticatorOverride` (set in setUp, reset in tearDown so
// no other file sees it). The issuer is FakeAoidEndpoint. Every value here is a
// hand-written literal.
//
// TEST LIST (one at a time, RED before GREEN):
//
//   1  unsupported -> no button, ever
//   2  supported but start does not advertise webauthn_discoverable -> none
//   3  the button appears only AFTER isSupported completes true
//   4  tap -> the challenge request, and the authenticator gets the publicKey
//      map once
//   5  assertion accepted -> AoidFlowComplete, no notice
//   6  cancelled -> silent, fields enabled, the password goes out on the
//      RESTARTED handle
//   7  notAssociated / failed -> one fixed sentence each
//   8  the issuer rejects the assertion -> the rejected-password sentence; the
//      password works afterwards
//   9  in flight: fields and submit disabled; a second tap does not start a
//      second attempt
//  10  a password that ADVANCES to mfa removes the button
//  11  the passkey notice clears when a password is submitted
//  12  a 503 on the challenge -> the state's own sentence and nothing else
//  16  an authenticator that THROWS (contract breach) -> a calm notice, the
//      form unlocked, and the breach surfaced in debug
//  17  an isSupported that THROWS -> no button

import 'dart:async';

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:eden_platform_flutter/src/aoid/passkey/aoid_passkey_authenticator.dart';
import 'package:eden_platform_flutter/src/aoid/passkey/aoid_passkey_resolver.dart';
import 'package:eden_ui_flutter/eden_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../auth/fixtures/fake_aoid_endpoint.dart';

const _copy = AoidLoginTheme();

/// A scripted authenticator. Each behaviour is opt-in.
final class _FakeAuthenticator implements AoidPasskeyAuthenticator {
  _FakeAuthenticator({this.supported = true, this.supportGate});

  final bool supported;

  /// When set, [isSupported] waits for it — lets a test see the frames before
  /// the answer arrives.
  final Completer<bool>? supportGate;

  int supportCalls = 0;
  final List<Map<String, dynamic>> received = [];

  @override
  Future<bool> isSupported() async {
    supportCalls++;
    final gate = supportGate;
    return gate == null ? supported : gate.future;
  }

  @override
  Future<AoidPasskeyAttempt> getAssertion(
    Map<String, dynamic> publicKey,
  ) async {
    received.add(publicKey);
    return const AoidPasskeyNotAsserted(AoidPasskeyFailure.cancelled);
  }
}

/// A flow that has completed `/oauth/native/start`.
Future<AoidNativeFlow> _startedFlow(FakeAoidEndpoint fake) async {
  final flow = AoidNativeFlow(
    client: AoidNativeClient(
      endpoints: AoidEndpoints.parse(kFakeAoidIssuer),
      httpClient: fake.client,
    ),
    clientId: kFakeNativeClientId,
    tenantId: kFakeTenantA,
    redirectUri: kFakeRedirectUri,
  );
  await flow.begin(codeChallenge: kFakeCodeChallenge);
  return flow;
}

/// Pumps the form. Does NOT pump a second frame: tests decide when the
/// isSupported probe is allowed to land.
Future<void> _pumpForm(WidgetTester tester, AoidNativeFlow flow) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: EdenTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: AoidLoginForm(controller: flow),
          ),
        ),
      ),
    ),
  );
}

Finder get _passkeyButton =>
    find.widgetWithText(EdenButton, _copy.passkeyLabel);

void main() {
  late FakeAoidEndpoint fake;

  setUp(() {
    fake = FakeAoidEndpoint(issuer: kFakeAoidIssuer);
  });

  tearDown(() {
    // Override hygiene: a leaked fake would make another file's test see it.
    debugAoidPasskeyAuthenticatorOverride = null;
  });

  group('1-3 the button is hidden until it is proven to work', () {
    testWidgets('1 unsupported: no passkey button, ever', (tester) async {
      final authenticator = _FakeAuthenticator(supported: false);
      debugAoidPasskeyAuthenticatorOverride = authenticator;
      final flow = await _startedFlow(fake);

      await _pumpForm(tester, flow);
      expect(find.text(_copy.passkeyLabel), findsNothing);
      await tester.pumpAndSettle();

      expect(authenticator.supportCalls, 1);
      expect(find.text(_copy.passkeyLabel), findsNothing);
      expect(find.byType(EdenButton), findsOneWidget, reason: 'submit only');
    });

    testWidgets('2 supported, but start did not advertise '
        'webauthn_discoverable: no button', (tester) async {
      debugAoidPasskeyAuthenticatorOverride = _FakeAuthenticator();
      fake.startAvailableMethods = const ['password'];
      final flow = await _startedFlow(fake);
      expect(flow.canUsePasskey, isFalse);

      await _pumpForm(tester, flow);
      await tester.pumpAndSettle();

      expect(find.text(_copy.passkeyLabel), findsNothing);
    });

    testWidgets('3 supported and advertised: the button appears only AFTER '
        'isSupported completes', (tester) async {
      final gate = Completer<bool>();
      debugAoidPasskeyAuthenticatorOverride = _FakeAuthenticator(
        supportGate: gate,
      );
      final flow = await _startedFlow(fake);

      await _pumpForm(tester, flow);
      expect(
        find.text(_copy.passkeyLabel),
        findsNothing,
        reason: 'first frame: support not yet proven, so no button',
      );
      await tester.pump();
      expect(find.text(_copy.passkeyLabel), findsNothing);

      gate.complete(true);
      // The answer lands in a microtask; the rebuild it schedules is drawn on
      // the following frame.
      await tester.pumpAndSettle();

      expect(_passkeyButton, findsOneWidget);
      // Below the password submit, in the secondary style.
      final buttons = tester
          .widgetList<EdenButton>(find.byType(EdenButton))
          .toList();
      expect(buttons.map((b) => b.label), [
        _copy.submitLabel,
        _copy.passkeyLabel,
      ]);
      expect(buttons.last.variant, EdenButtonVariant.secondary);
    });
  });
}
