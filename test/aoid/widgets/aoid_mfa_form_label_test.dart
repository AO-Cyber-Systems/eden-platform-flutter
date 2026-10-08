// TRD 52-04 item 15 — the MFA picker's labels for the two WebAuthn factors.
//
// `webauthn_discoverable` is a PASSKEY (a discoverable platform credential);
// `webauthn` is an email-pinned security key. They used to share the label
// "Security key". No earlier test asserted either label, so this one pins both,
// plus one unrelated label to prove the map is still read.
//
// Behaviour is otherwise unchanged (Objective 52 open question Q3): neither
// WebAuthn factor is completed at this step in-app yet.
//
// Every value is a hand-written literal.

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:eden_ui_flutter/eden_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../auth/fixtures/fake_aoid_endpoint.dart';

/// A flow whose password ADVANCED to the MFA step offering [methods].
Future<AoidNativeFlow> _flowAtMfa(List<String> methods) async {
  final fake = FakeAoidEndpoint(issuer: kFakeAoidIssuer)
    ..scriptNativeCeremony([
      FakeNativeAdvance(next: 'mfa', availableMethods: methods),
    ]);
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
  await flow.submitPassword(email: 'ada@fake-aoid.test', password: 'pw');
  return flow;
}

Future<void> _pumpMfa(WidgetTester tester, AoidNativeFlow flow) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: EdenTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: AoidMfaForm(controller: flow),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _chip(String label) => find.widgetWithText(ChoiceChip, label);

void main() {
  testWidgets('15 webauthn_discoverable is labelled "Passkey" and webauthn '
      '"Security key"', (tester) async {
    final flow = await _flowAtMfa(const [
      'totp',
      'webauthn',
      'webauthn_discoverable',
    ]);
    expect((flow.state as AoidFlowAwaitingFactor).next, 'mfa');

    await _pumpMfa(tester, flow);

    expect(find.byType(ChoiceChip), findsNWidgets(3));
    expect(_chip('Authenticator app'), findsOneWidget);
    expect(_chip('Security key'), findsOneWidget, reason: 'webauthn only');
    expect(_chip('Passkey'), findsOneWidget, reason: 'webauthn_discoverable');
  });

  testWidgets('15b selecting the Passkey chip changes no behaviour: no code '
      'field, no submit (Q3 is open)', (tester) async {
    final flow = await _flowAtMfa(const ['totp', 'webauthn_discoverable']);
    await _pumpMfa(tester, flow);
    expect(find.byType(EdenInput), findsOneWidget, reason: 'totp first');

    await tester.tap(_chip('Passkey'));
    await tester.pump();

    expect(find.byType(EdenInput), findsNothing);
    expect(find.byType(EdenButton), findsNothing);
    expect(find.text('Use your security key to continue.'), findsOneWidget);
  });
}
