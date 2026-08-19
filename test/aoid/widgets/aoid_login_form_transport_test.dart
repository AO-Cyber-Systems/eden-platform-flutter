// THE CONTAINMENT PROOF for the sealed AOID forms (the spec, items 8-14).
//
// The companion file `sealed_form_no_leak_test.dart` proves the forms hand out
// no API. That is only half the guarantee: a widget with no callbacks could
// still POST the password to the embedding app's own backend. This file closes
// the other half by asserting where the credential actually goes.
//
// Item 8 is the load-bearing one — the design notes guarantee #1 made mechanical. It
// asserts three things at once, and the third is the one people leave out:
//
//   1. the request body carries the password        (it went somewhere)
//   2. the destination host is the AOID issuer      (it went to AOID)
//   3. the destination host is NOT the app base URL (it went ONLY to AOID)
//
// Assertion 3 is not redundant with 2. A test that checked only "the password
// is in a request body" passes just as happily when the form posts it to the
// consuming app's backend, which is precisely what the issuer forbids. The
// fixture deliberately gives the issuer and the app DIFFERENT hosts
// (`auth.fake-aoid.test` vs `app.fake-aoid.test`) so the distinction is real
// rather than notional.
//
// Every fixture value here is a hand-written literal (no_llm_test_data).

import 'dart:io';

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:eden_ui_flutter/eden_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../auth/fixtures/fake_aoid_endpoint.dart';

/// The password this test types. A literal, and never a real credential.
const kTypedPassword = 'correct-horse-battery-staple';
const kTypedEmail = 'ada@fake-aoid.test';

/// The AOID issuer the sealed form must reach.
final kIssuerUri = Uri.parse(kFakeAoidIssuer);

/// The CONSUMING APP's own origin — from the fixture's redirect URI. The
/// password must never be seen here. Distinct host from the issuer on purpose.
final kAppBaseUri = Uri.parse(kFakeRedirectUri);

FakeAoidEndpoint _newFake() => FakeAoidEndpoint(issuer: kFakeAoidIssuer);

/// A flow that has already completed `/oauth/native/start`, so the form's
/// submit has a live handle to present.
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

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? EdenTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('D3 — the password travels from the sealed form to AOID, and only '
      'to AOID', () {
    // -----------------------------------------------------------------------
    // 8. THE PROOF.
    // -----------------------------------------------------------------------
    testWidgets('8. the password reaches the AOID issuer and not the app '
        'backend', (tester) async {
      final fake = _newFake();
      fake.scriptNativeCeremony(const [FakeNativeTerminal('auth-code-alpha')]);
      final flow = await _startedFlow(fake);

      await _pump(tester, AoidLoginForm(controller: flow));

      // The `.last` selector is pinned by the assertions in item 9; here we
      // additionally prove the field we typed into is the OBSCURED one, so a
      // future extra field cannot silently redirect this test at the email box
      // and leave it passing while proving nothing.
      final passwordField = find.byType(EdenInput).last;
      expect(
        tester.widget<EdenInput>(passwordField).obscureText,
        isTrue,
        reason:
            'The last EdenInput is no longer the password field. Item 8 would '
            'then be typing its "password" into some other box and asserting '
            'about a request that never carried a credential.',
      );

      await tester.enterText(find.byType(EdenInput).first, kTypedEmail);
      await tester.enterText(passwordField, kTypedPassword);
      await tester.tap(find.byType(EdenButton));
      await tester.pumpAndSettle();

      final req = fake.capturedRequests.last;

      // (1) It went somewhere, carrying the credential.
      expect(
        req.bodyFields['password'],
        kTypedPassword,
        reason:
            'The sealed form did not put the typed password on the wire. The '
            'password IS in the request body by design — that is the whole '
            'point of a no-redirect ceremony — so its absence means the submit '
            'path is broken, not that containment improved.',
      );

      // (2) It went to AOID.
      expect(
        req.url.host,
        kIssuerUri.host,
        reason:
            'the design notes guarantee #1: the password goes straight from the '
            'widget to the AOID issuer, NEVER to the consuming app backend.',
      );
      expect(req.url.path, '/oauth/native/verify');

      // (3) It went ONLY to AOID. Not redundant with (2): a test asserting
      // only that the password is present would pass if it had been posted to
      // the app's own backend.
      expect(
        req.url.host,
        isNot(kAppBaseUri.host),
        reason:
            'The password was posted to the CONSUMING APP\'S host '
            '(${kAppBaseUri.host}). That is exactly what the issuer forbids: '
            'the app must never be in a position to see the credential, and a '
            'containment guarantee that only holds when the app behaves is not '
            'a guarantee.',
      );

      //...and no request in the whole exchange went anywhere but the issuer.
      for (final r in fake.capturedRequests) {
        expect(
          r.url.host,
          kIssuerUri.host,
          reason:
              'A request in this ceremony went to ${r.url.host}. Every single '
              'one must go to the AOID issuer.',
        );
      }

      // Cross-check against the fixture's own recording of the wire bytes, so
      // this does not rest on a single accessor's parsing.
      expect(fake.nativeRequests.last.fields['password'], kTypedPassword);
      expect(fake.nativeRequests.last.rawBody, contains('password='));
    });

    // -----------------------------------------------------------------------
    // 9. Pin the field count so item 8's selector cannot drift.
    // -----------------------------------------------------------------------
    testWidgets('9. the form renders exactly two inputs, in a known order', (
      tester,
    ) async {
      final flow = await _startedFlow(_newFake());
      await _pump(tester, AoidLoginForm(controller: flow));

      expect(
        find.byType(EdenInput),
        findsNWidgets(2),
        reason:
            'AoidLoginForm renders exactly an identifier field and a password '
            'field. If that changed, item 8\'s `.last` selector may now be '
            'targeting a different box — update both together.',
      );
      final inputs = tester
          .widgetList<EdenInput>(find.byType(EdenInput))
          .toList();
      expect(inputs.first.obscureText, isFalse);
      expect(inputs.last.obscureText, isTrue);
      expect(
        find.byType(EdenButton),
        findsOneWidget,
        reason: 'One submit control; item 8 taps it byType.',
      );
    });

    // -----------------------------------------------------------------------
    // 10. Theme copy renders, and brandMark is PLACED (not built).
    // -----------------------------------------------------------------------
    testWidgets('10. relyingPartyName renders and brandMark is placed', (
      tester,
    ) async {
      final flow = await _startedFlow(_newFake());
      const mark = Icon(Icons.shield_outlined, key: ValueKey('brand-mark'));

      await _pump(
        tester,
        AoidLoginForm(
          controller: flow,
          theme: const AoidLoginTheme(
            relyingPartyName: 'AODex',
            brandMark: mark,
          ),
        ),
      );

      expect(find.text('to continue to AODex'), findsOneWidget);
      expect(find.byKey(const ValueKey('brand-mark')), findsOneWidget);
      expect(find.text('Sign in'), findsWidgets); // headline + submit label
    });

    testWidgets('10b. an empty relyingPartyName renders no dangling phrase', (
      tester,
    ) async {
      final flow = await _startedFlow(_newFake());
      await _pump(tester, AoidLoginForm(controller: flow));

      expect(
        find.textContaining('to continue to'),
        findsNothing,
        reason:
            'With no relying-party name the phrase must be omitted entirely, '
            'not rendered with an empty tail.',
      );
    });

    // -----------------------------------------------------------------------
    // 11. THEMING IS AMBIENT — no parameter is passed in either pump.
    // -----------------------------------------------------------------------
    testWidgets('11. the form inherits the surrounding EdenTheme with no '
        'parameter passed', (tester) async {
      // GOTCHA, measured rather than assumed: MaterialApp wraps its child in
      // an AnimatedTheme, so a theme CHANGE lerps over kThemeAnimationDuration
      // (200ms) instead of applying on the next frame. With a single `pump()`
      // the second tree still renders the FIRST theme — a probe showed
      // `Theme.of(context).brightness == Brightness.light` under
      // `EdenTheme.dark()`, and both samples came back identical. Settle the
      // animation or this test compares a colour with itself.
      Color? accentNow() =>
          tester.widget<Container>(find.byKey(kAoidAccentRuleKey)).color;

      Brightness brightnessNow() =>
          Theme.of(tester.element(find.byType(AoidLoginForm))).brightness;

      final flowLight = await _startedFlow(_newFake());
      // NOTE: the widget below is constructed IDENTICALLY in both pumps. The
      // only difference is the ThemeData wrapped around it — no parameter of
      // any kind is passed to AoidLoginForm.
      await _pump(
        tester,
        AoidLoginForm(controller: flowLight),
        theme: EdenTheme.light(),
      );
      await tester.pumpAndSettle();
      final light = accentNow();
      expect(brightnessNow(), Brightness.light);

      final flowDark = await _startedFlow(_newFake());
      await _pump(
        tester,
        AoidLoginForm(controller: flowDark),
        theme: EdenTheme.dark(),
      );
      await tester.pumpAndSettle();
      final dark = accentNow();
      expect(
        brightnessNow(),
        Brightness.dark,
        reason:
            'The dark theme never reached the widget, so the comparison below '
            'would be a colour against itself. See the AnimatedTheme note above.',
      );

      expect(light, isNotNull);
      expect(dark, isNotNull);
      expect(
        light,
        isNot(dark),
        reason:
            'The accent rule rendered the same colour under EdenTheme.light() '
            'and EdenTheme.dark(). Either the colour is hardcoded — which the '
            'source gate forbids — or the form is not reading Theme.of(context) '
            'at all. Theming must be AMBIENT: the sealed form takes no colour '
            'parameter, so inheritance is the only way a host brands it.',
      );
      expect(
        light,
        EdenTheme.light().colorScheme.primary,
        reason:
            'The accent rule must be the ambient brand colour '
            '(EdenTheme.brandColor defaults to AOCyber gold), not an arbitrary '
            'one.',
      );
      expect(dark, EdenTheme.dark().colorScheme.primary);
    });

    // -----------------------------------------------------------------------
    // 12. Autofill hints survive.
    // -----------------------------------------------------------------------
    testWidgets('12. the password field keeps AutofillHints.password', (
      tester,
    ) async {
      final flow = await _startedFlow(_newFake());
      await _pump(tester, AoidLoginForm(controller: flow));

      final inputs = tester
          .widgetList<EdenInput>(find.byType(EdenInput))
          .toList();
      expect(
        inputs.last.autofillHints,
        contains(AutofillHints.password),
        reason:
            'The OS password manager is a SINK, not a leak to app-owned Dart. '
            'Dropping the hint makes the form worse without making it safer — '
            'it pushes users towards weaker, memorable passwords.',
      );
      expect(inputs.first.autofillHints, contains(AutofillHints.username));
    });

    // -----------------------------------------------------------------------
    // 13. Teardown: cleared before disposed, and nothing survives it.
    // -----------------------------------------------------------------------
    test('13a. dispose() clears the controller BEFORE disposing it', () {
      // A source assertion, and deliberately so: the controller is private —
      // that is the entire design — so no runtime test can reach it to observe
      // the ordering. Asserting the order in source is the honest form of this
      // check, not a weaker substitute for one that could exist.
      final src = File(
        'lib/src/aoid/widgets/aoid_login_form.dart',
      ).readAsStringSync();
      final clearAt = src.indexOf('_passwordCtrl.clear()');
      final disposeAt = src.indexOf('_passwordCtrl.dispose()');
      expect(clearAt, greaterThan(-1), reason: 'no clear() call at all');
      expect(disposeAt, greaterThan(-1), reason: 'no dispose() call at all');
      expect(
        clearAt,
        lessThan(disposeAt),
        reason:
            'clear() must precede dispose(); calling it after would throw. '
            'NOTE this is BEST-EFFORT and must not be described as erasure: '
            'Dart cannot zero a String, so clear() drops a reference rather '
            'than scrubbing bytes out of memory.',
      );
    });

    testWidgets('13b. no form state survives a route change', (tester) async {
      final flow = await _startedFlow(_newFake());
      await _pump(tester, AoidLoginForm(controller: flow));
      await tester.enterText(find.byType(EdenInput).last, kTypedPassword);
      await tester.pump();

      // Tear the form down completely.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('elsewhere'))),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AoidLoginForm), findsNothing);
      expect(
        find.byType(EdenInput),
        findsNothing,
        reason:
            'A field outlived the form. The most likely cause is an accidental '
            'static cache holding State after teardown — which would also mean '
            'the plaintext outlives the screen the user closed.',
      );
      expect(
        tester.takeException(),
        isNull,
        reason:
            'Teardown threw. A controller used after disposal would surface '
            'here, and it would mean the form kept a live reference to the '
            'credential past its own lifetime.',
      );
    });

    // -----------------------------------------------------------------------
    // 14. AoidMfaForm's picker, including the EMPTY case that is normal.
    // -----------------------------------------------------------------------
    testWidgets('14a. AoidMfaForm renders a picker from a non-empty '
        'availableMethods', (tester) async {
      final fake = _newFake();
      fake.scriptNativeCeremony(const [
        FakeNativeAdvance(
          next: 'mfa',
          availableMethods: ['totp', 'backup_code'],
        ),
      ]);
      final flow = await _startedFlow(fake);
      await flow.submitPassword(email: kTypedEmail, password: kTypedPassword);

      final state = flow.state;
      expect(state, isA<AoidFlowAwaitingFactor>());
      expect((state as AoidFlowAwaitingFactor).availableMethods, [
        'totp',
        'backup_code',
      ]);

      await _pump(tester, AoidMfaForm(controller: flow));

      expect(find.byType(ChoiceChip), findsNWidgets(2));
      expect(find.text('Authenticator app'), findsOneWidget);
      expect(find.text('Backup code'), findsOneWidget);
      expect(
        find.byType(EdenInput),
        findsOneWidget,
        reason: 'the code field itself must still be there',
      );
    });

    testWidgets('14b. AoidMfaForm renders sensibly when availableMethods is '
        'EMPTY — the normal early state', (tester) async {
      // the spec refuses to emit a per-identity method list before a factor has
      // succeeded, because that turns the endpoint into an enumeration oracle.
      // So the empty list is the COMMON path, not an edge case, and a picker
      // that rendered empty chrome (or threw) would be a bug in the common path.
      final fake = _newFake()..startAvailableMethods = const [];
      final flow = await _startedFlow(fake);

      expect((flow.state as AoidFlowAwaitingFactor).availableMethods, isEmpty);

      await _pump(tester, AoidMfaForm(controller: flow));

      expect(
        find.byType(ChoiceChip),
        findsNothing,
        reason:
            'An empty availableMethods must render NO picker at all — not an '
            'empty one. There is no choice to present.',
      );
      expect(
        find.byType(EdenInput),
        findsOneWidget,
        reason:
            'The form must still be usable with no methods advertised: AOID '
            'knows which factor it is waiting for, and the code goes to the '
            'same field either way.',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('14c. the MFA code reaches the AOID issuer too', (
      tester,
    ) async {
      // The second factor is a credential as well, so it gets the same proof.
      final fake = _newFake()..startAvailableMethods = const [];
      fake.scriptNativeCeremony(const [FakeNativeTerminal('auth-code-beta')]);
      final flow = await _startedFlow(fake);

      await _pump(tester, AoidMfaForm(controller: flow));
      await tester.enterText(find.byType(EdenInput), '123456');
      await tester.tap(find.byType(EdenButton));
      await tester.pumpAndSettle();

      final req = fake.capturedRequests.last;
      expect(req.bodyFields['otp'], '123456');
      expect(req.url.host, kIssuerUri.host);
      expect(req.url.host, isNot(kAppBaseUri.host));
    });
  });
}
