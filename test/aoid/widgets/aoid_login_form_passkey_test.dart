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
//      form unlocked, and the breach reported with a fixed message
//  17  an isSupported that THROWS -> no button, the breach reported

import 'dart:async';

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:eden_platform_flutter/src/aoid/passkey/aoid_passkey_authenticator.dart';
import 'package:eden_platform_flutter/src/aoid/passkey/aoid_passkey_resolver.dart';
import 'package:eden_ui_flutter/eden_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../auth/fixtures/fake_aoid_endpoint.dart';

const _copy = AoidLoginTheme();

/// A discoverable challenge in the shape AOID's
/// `BeginDiscoverableMediatedLogin` emits.
const String _challengeJson =
    '{"publicKey":{"challenge":"q2Xv-7kd_R0aZ9mPq3sT1uVwX8yZ0aB2cD4eF6gH8iI",'
    '"timeout":300000,"rpId":"auth.fake-aoid.test","allowCredentials":[],'
    '"userVerification":"preferred"},"mediation":"conditional"}';

const _challengeStep = FakeNativeAdvance(
  next: 'webauthn',
  webauthnChallenge: _challengeJson,
);

/// What the platform half would assemble. The form never sees it; it is here
/// only so the fake authenticator has something to hand the flow.
const String _assertionJson =
    '{"id":"cR3d-Ent_1d-alpha","rawId":"cR3d-Ent_1d-alpha",'
    '"type":"public-key","authenticatorAttachment":"platform",'
    '"response":{"clientDataJSON":"eyJ0eXBlIjoid2ViYXV0aG4uZ2V0In0-_Q2xp",'
    '"authenticatorData":"SZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2M-BQ",'
    '"signature":"MEUCIQD-_c2lnbmF0dXJlLWFscGhh_AiB-zz",'
    '"userHandle":"dXNlci1oYW5kbGUtYWxwaGE"},"clientExtensionResults":{}}';

const _email = 'ada@fake-aoid.test';
const _password = 'correct-horse-battery-staple';

// The closed passkey copy (TRD 52-04), byte for byte.
const _rejected = 'That did not work. Check your details and try again.';
const _unavailable =
    'Passkey sign-in is not available on this device right now. '
    'Use your password instead.';
const _failed =
    'Passkey sign-in could not be completed. Use your password instead.';
const _temporarilyUnavailable =
    'Sign-in is temporarily unavailable. Try again in a moment.';
const _couldNotComplete = 'Sign-in could not be completed.';

/// Every sentence the form can show, so a test can assert "nothing else".
const _allNotices = <String>[
  _rejected,
  _unavailable,
  _failed,
  _temporarilyUnavailable,
  _couldNotComplete,
  'This sign-in session has ended. Start again.',
  'Continue in your browser to finish signing in.',
];

/// A scripted authenticator. Each behaviour is opt-in.
final class _FakeAuthenticator implements AoidPasskeyAuthenticator {
  _FakeAuthenticator({
    this.supported = true,
    this.supportGate,
    this.attempt = const AoidPasskeyNotAsserted(AoidPasskeyFailure.cancelled),
    this.attemptGate,
    this.throwFromSupport = false,
    this.throwFromAssertion = false,
  });

  final bool supported;

  /// When set, [isSupported] waits for it — lets a test see the frames before
  /// the answer arrives.
  final Completer<bool>? supportGate;

  final AoidPasskeyAttempt attempt;

  /// When set, [getAssertion] waits for it — the "sheet is up" window.
  final Completer<AoidPasskeyAttempt>? attemptGate;

  /// Breaks the interface's never-throws contract, to prove the form copes.
  final bool throwFromSupport;
  final bool throwFromAssertion;

  int supportCalls = 0;
  final List<Map<String, dynamic>> received = [];

  @override
  Future<bool> isSupported() async {
    supportCalls++;
    if (throwFromSupport) throw StateError('fake: isSupported broke');
    final gate = supportGate;
    return gate == null ? supported : gate.future;
  }

  @override
  Future<AoidPasskeyAttempt> getAssertion(
    Map<String, dynamic> publicKey,
  ) async {
    received.add(publicKey);
    if (throwFromAssertion) throw StateError('fake: getAssertion broke');
    final gate = attemptGate;
    return gate == null ? attempt : gate.future;
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

/// Pumps the form, lets the support probe land, and checks the button is on
/// offer — the precondition of every tap test.
Future<void> _pumpReady(WidgetTester tester, AoidNativeFlow flow) async {
  await _pumpForm(tester, flow);
  await tester.pumpAndSettle();
  expect(
    find.widgetWithText(EdenButton, _copy.passkeyLabel),
    findsOneWidget,
    reason: 'precondition: the passkey button is offered',
  );
}

/// Pumps frames until [done] holds — for the windows where a spinner is
/// animating and `pumpAndSettle` would never return.
Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 20 && !done(); i++) {
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'condition not reached after 20 frames');
}

Finder get _submitButton => find.widgetWithText(EdenButton, _copy.submitLabel);

bool _fieldsEnabled(WidgetTester tester) => tester
    .widgetList<EdenInput>(find.byType(EdenInput))
    .every((input) => input.enabled);

bool _fieldsDisabled(WidgetTester tester) => tester
    .widgetList<EdenInput>(find.byType(EdenInput))
    .every((input) => !input.enabled);

bool _submitEnabled(WidgetTester tester) {
  final button = tester.widget<EdenButton>(_submitButton);
  return button.onPressed != null && !button.loading;
}

/// No sentence from the form's closed vocabulary is on screen.
void _expectNoNotice() {
  for (final notice in _allNotices) {
    expect(find.text(notice), findsNothing, reason: notice);
  }
}

/// Exactly [expected] is on screen, once, and no other notice is.
void _expectOnlyNotice(String expected) {
  expect(find.text(expected), findsOneWidget);
  for (final notice in _allNotices.where((n) => n != expected)) {
    expect(find.text(notice), findsNothing, reason: notice);
  }
}

Finder get _passkeyButton =>
    find.widgetWithText(EdenButton, _copy.passkeyLabel);

void main() {
  late FakeAoidEndpoint fake;

  List<RecordedNativeRequest> starts() => fake.nativeRequests
      .where((r) => r.path.endsWith('/oauth/native/start'))
      .toList();

  List<RecordedNativeRequest> verifies() => fake.nativeRequests
      .where((r) => r.path.endsWith('/oauth/native/verify'))
      .toList();

  Future<void> submitPassword(WidgetTester tester) async {
    await tester.enterText(find.byType(EdenInput).first, _email);
    await tester.enterText(find.byType(EdenInput).last, _password);
    await tester.tap(_submitButton);
    await tester.pumpAndSettle();
  }

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

  group('4-12 the tap path', () {
    testWidgets('4 tap: the challenge goes out on the current handle and the '
        'authenticator is called once with its publicKey map', (tester) async {
      fake.scriptNativeCeremony([_challengeStep]);
      final authenticator = _FakeAuthenticator();
      debugAoidPasskeyAuthenticatorOverride = authenticator;
      final flow = await _startedFlow(fake);
      await _pumpReady(tester, flow);

      await tester.tap(_passkeyButton);
      await tester.pumpAndSettle();

      final challenge = verifies().single.fields;
      expect(challenge['method'], 'webauthn_discoverable_challenge');
      expect(challenge['auth_session'], kFakeHandle1);
      expect(challenge, isNot(contains('password')));
      expect(authenticator.received, hasLength(1));
      expect(authenticator.received.single, {
        'challenge': 'q2Xv-7kd_R0aZ9mPq3sT1uVwX8yZ0aB2cD4eF6gH8iI',
        'timeout': 300000,
        'rpId': 'auth.fake-aoid.test',
        'allowCredentials': <Object?>[],
        'userVerification': 'preferred',
      });
    });

    testWidgets('6 cancelled: silent, the fields enabled, and the password '
        'goes out on the RESTARTED handle', (tester) async {
      fake.scriptNativeCeremony([
        _challengeStep,
        const FakeNativeTerminal('code-password-alpha'),
      ]);
      debugAoidPasskeyAuthenticatorOverride = _FakeAuthenticator(
        attempt: const AoidPasskeyNotAsserted(AoidPasskeyFailure.cancelled),
      );
      final flow = await _startedFlow(fake);
      await _pumpReady(tester, flow);

      await tester.tap(_passkeyButton);
      await tester.pumpAndSettle();

      _expectNoNotice();
      expect(_fieldsEnabled(tester), isTrue);
      expect(_submitEnabled(tester), isTrue);
      expect(starts(), hasLength(2), reason: 'the flow restarted once');
      // The handle the restart's /start minted.
      final restarted = fake.mintedNativeHandles.last;
      expect(restarted, isNot(kFakeHandle1));
      // And the passkey is on offer again on the fresh ceremony.
      expect(_passkeyButton, findsOneWidget);

      await submitPassword(tester);

      final password = verifies().last.fields;
      expect(password['method'], 'password');
      expect(password['auth_session'], restarted);
      expect(password['password'], _password);
      expect(flow.state, isA<AoidFlowComplete>());
      _expectNoNotice();
    });

    testWidgets('9 in flight: the fields and the submit are disabled, and a '
        'second tap does not start a second attempt', (tester) async {
      final sheet = Completer<AoidPasskeyAttempt>();
      fake.scriptNativeCeremony([_challengeStep]);
      final authenticator = _FakeAuthenticator(attemptGate: sheet);
      debugAoidPasskeyAuthenticatorOverride = authenticator;
      final flow = await _startedFlow(fake);
      await _pumpReady(tester, flow);

      await tester.tap(_passkeyButton);
      await _pumpUntil(tester, () => authenticator.received.isNotEmpty);

      // The OS sheet is "up".
      expect(_fieldsDisabled(tester), isTrue);
      expect(tester.widget<EdenButton>(_submitButton).onPressed, isNull);
      expect(tester.widget<EdenButton>(_passkeyButton).loading, isTrue);

      // An incidental rebuild (theme, keyboard) while the ceremony sits at
      // webauthn_pending must not make the in-flight button vanish.
      tester.element(find.byType(AoidLoginForm)).markNeedsBuild();
      await tester.pump();
      expect(_passkeyButton, findsOneWidget);
      expect(tester.widget<EdenButton>(_passkeyButton).loading, isTrue);

      await tester.tap(_passkeyButton, warnIfMissed: false);
      await tester.tap(_submitButton, warnIfMissed: false);
      await tester.pump();
      await tester.pump();
      expect(authenticator.received, hasLength(1), reason: 'one attempt');
      expect(verifies(), hasLength(1), reason: 'the challenge only');

      sheet.complete(
        const AoidPasskeyNotAsserted(AoidPasskeyFailure.cancelled),
      );
      await tester.pumpAndSettle();

      expect(_fieldsEnabled(tester), isTrue);
      expect(_submitEnabled(tester), isTrue);
      expect(authenticator.received, hasLength(1));
      expect(verifies(), hasLength(1));
      expect(starts(), hasLength(2));
    });

    testWidgets('5 the assertion is accepted: AoidFlowComplete, no notice', (
      tester,
    ) async {
      fake.scriptNativeCeremony([
        _challengeStep,
        const FakeNativeTerminal('code-passkey-alpha'),
      ]);
      debugAoidPasskeyAuthenticatorOverride = _FakeAuthenticator(
        attempt: const AoidPasskeyAsserted(_assertionJson),
      );
      final flow = await _startedFlow(fake);
      await _pumpReady(tester, flow);

      await tester.tap(_passkeyButton);
      await tester.pumpAndSettle();

      expect(flow.state, isA<AoidFlowComplete>());
      expect(flow.authorizationCode, 'code-passkey-alpha');
      expect(verifies().last.fields['method'], 'webauthn_discoverable');
      _expectNoNotice();
      expect(starts(), hasLength(1), reason: 'no restart after success');
    });

    for (final (failure, sentence) in const [
      (AoidPasskeyFailure.notAssociated, _unavailable),
      (AoidPasskeyFailure.unsupported, _unavailable),
      (AoidPasskeyFailure.failed, _failed),
    ]) {
      testWidgets('7 ${failure.name}: exactly one fixed sentence, and the form '
          'stays usable', (tester) async {
        fake.scriptNativeCeremony([_challengeStep]);
        debugAoidPasskeyAuthenticatorOverride = _FakeAuthenticator(
          attempt: AoidPasskeyNotAsserted(failure),
        );
        final flow = await _startedFlow(fake);
        await _pumpReady(tester, flow);

        await tester.tap(_passkeyButton);
        await tester.pumpAndSettle();

        _expectOnlyNotice(sentence);
        expect(_fieldsEnabled(tester), isTrue);
        expect(_submitEnabled(tester), isTrue);
      });
    }

    testWidgets('8 the issuer rejects the assertion: the rejected-password '
        'sentence, and the password works afterwards', (tester) async {
      fake.scriptNativeCeremony([
        _challengeStep,
        const FakeNativeReject(),
        const FakeNativeTerminal('code-password-alpha'),
      ]);
      debugAoidPasskeyAuthenticatorOverride = _FakeAuthenticator(
        attempt: const AoidPasskeyAsserted(_assertionJson),
      );
      final flow = await _startedFlow(fake);
      await _pumpReady(tester, flow);

      await tester.tap(_passkeyButton);
      await tester.pumpAndSettle();

      _expectOnlyNotice('That did not work. Check your details and try again.');
      expect(_fieldsEnabled(tester), isTrue);

      final restarted = fake.mintedNativeHandles.last;
      await submitPassword(tester);

      expect(verifies().last.fields['method'], 'password');
      expect(verifies().last.fields['auth_session'], restarted);
      expect(flow.state, isA<AoidFlowComplete>());
      _expectNoNotice();
    });

    testWidgets('10 a password that ADVANCES to mfa removes the button', (
      tester,
    ) async {
      fake.scriptNativeCeremony([
        const FakeNativeAdvance(next: 'mfa', availableMethods: ['totp']),
      ]);
      debugAoidPasskeyAuthenticatorOverride = _FakeAuthenticator();
      final flow = await _startedFlow(fake);
      await _pumpReady(tester, flow);

      await submitPassword(tester);

      expect((flow.state as AoidFlowAwaitingFactor).next, 'mfa');
      expect(flow.canUsePasskey, isFalse);
      expect(find.text(_copy.passkeyLabel), findsNothing);
    });

    testWidgets('11 the passkey notice clears when a password is submitted', (
      tester,
    ) async {
      fake.scriptNativeCeremony([
        _challengeStep,
        // The password meets a 503: the STATE's sentence must now show, not
        // the stale passkey one.
        const FakeNativeUnavailable(),
      ]);
      debugAoidPasskeyAuthenticatorOverride = _FakeAuthenticator(
        attempt: const AoidPasskeyNotAsserted(AoidPasskeyFailure.notAssociated),
      );
      final flow = await _startedFlow(fake);
      await _pumpReady(tester, flow);
      await tester.tap(_passkeyButton);
      await tester.pumpAndSettle();
      _expectOnlyNotice(_unavailable);

      await submitPassword(tester);

      expect(flow.state, isA<AoidFlowUnavailable>());
      _expectOnlyNotice(_temporarilyUnavailable);
    });

    testWidgets('12 a 503 on the challenge: the state\'s own sentence and '
        'nothing else', (tester) async {
      fake.scriptNativeCeremony([const FakeNativeUnavailable()]);
      final authenticator = _FakeAuthenticator(
        attempt: const AoidPasskeyAsserted(_assertionJson),
      );
      debugAoidPasskeyAuthenticatorOverride = authenticator;
      final flow = await _startedFlow(fake);
      await _pumpReady(tester, flow);

      await tester.tap(_passkeyButton);
      await tester.pumpAndSettle();

      expect(flow.state, isA<AoidFlowUnavailable>());
      _expectOnlyNotice(_temporarilyUnavailable);
      expect(authenticator.received, isEmpty);
      // The handle survived (52-03): either factor may be tried again.
      expect(_passkeyButton, findsOneWidget);
      expect(_fieldsEnabled(tester), isTrue);
      expect(_submitEnabled(tester), isTrue);
    });
  });

  group('16-17 an authenticator that breaks its never-throws contract', () {
    testWidgets('16 getAssertion throws: a calm fixed sentence, the form '
        'unlocked, and the breach reported', (tester) async {
      fake.scriptNativeCeremony([_challengeStep]);
      debugAoidPasskeyAuthenticatorOverride = _FakeAuthenticator(
        throwFromAssertion: true,
      );
      final flow = await _startedFlow(fake);
      await _pumpReady(tester, flow);

      await tester.tap(_passkeyButton);
      await tester.pumpAndSettle();

      // Reported, not masked — with a FIXED message: nothing of the thrown
      // object rides along.
      final breach = tester.takeException();
      expect(breach, isA<FlutterError>());
      expect('$breach', contains('AoidPasskeyAuthenticator threw'));
      expect('$breach', isNot(contains('fake: getAssertion broke')));

      // Not the `failed` sentence: the flow did not restart, so "use your
      // password instead" would be untrue.
      _expectOnlyNotice(_couldNotComplete);
      expect(_fieldsEnabled(tester), isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // AOID is at webauthn_pending; only a new ceremony offers it again.
      expect(find.text(_copy.passkeyLabel), findsNothing);
    });

    testWidgets('17 isSupported throws: no button, ever', (tester) async {
      final authenticator = _FakeAuthenticator(throwFromSupport: true);
      debugAoidPasskeyAuthenticatorOverride = authenticator;
      final flow = await _startedFlow(fake);

      await _pumpForm(tester, flow);
      await tester.pumpAndSettle();

      expect(authenticator.supportCalls, 1);
      expect(find.text(_copy.passkeyLabel), findsNothing);
      final breach = tester.takeException();
      expect(breach, isA<FlutterError>(), reason: 'reported, not masked');
      expect('$breach', isNot(contains('fake: isSupported broke')));
    });
  });
}
