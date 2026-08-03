// TRD 50-08 — the client half of objective 49's /oauth/native/* contract.
//
// TEST LIST (written first; RED before GREEN, one at a time).
//
// Fixture non-vacuity (task 1 — these drive the FAKE directly, no client yet):
//   F1  the fake serves POST /oauth/native/start and mints a handle
//   F2  the fake ROTATES: every non-terminal verify returns a NEW handle
//   F3  replay / expiry / unknown-handle / cross-tenant produce BYTE-IDENTICAL
//       responses — status, every header, and the raw body. If the FAKE
//       distinguishes them, the client's own lossiness test (item 8) passes
//       vacuously. This is the 49-08 lesson: a negative test that asserts
//       exactly what a broken implementation also produces proves nothing.
//   F4  the fake rejects a JSON content-type, exactly as 49-08's isFormContent
//       does ("NEVER accept JSON request bodies on OAuth endpoints")
//
// Client (task 2):
//   1   start() POSTs form-encoded to /oauth/native/start with client_id and
//       tenant_id IN THE BODY, and parses auth_session / next /
//       available_methods
//   2   start() sends NO application header other than the content type —
//       the CORS-simple-request guard
//   3   the content type is application/x-www-form-urlencoded, never JSON
//   4   verify() POSTs the full field set form-encoded
//   5   a terminal verify() returning {"authorization_code": "..."} yields the
//       code  — NOTE: the wire key is `authorization_code`, NOT `code`; the
//       TRD said `code` and objective 49 shipped `authorization_code`
//   6   the handle ROTATES: two sequential verify() calls send two DIFFERENT
//       auth_session values, the second being the one the first response
//       returned — asserted on the RECORDED REQUEST BODIES
//   7   {"error":"invalid_session"} yields AoidError with code invalidSession
//   8   the error surface does not distinguish replay from expiry from
//       unknown-handle — same code AND same message
//   9   {"error":"redirect_to_web","authorization_url":"…"} maps to 50-04's
//       RedirectRequired, NOT to a failure and NOT to an AoidError
//   10  invalid_client and invalid_request map to their codes
//   11  no secret in any message: neither the password, the TOTP code, nor the
//       auth_session appears in the thrown object's toString()
//   12  a transport-level failure (socket error / 500 / 503) is a DIFFERENT
//       type from an authentication failure, so a blip cannot be turned into a
//       sign-out (the restoreSession defect, not repeated)
//   13  available_methods absent is an empty list, not an error
//   14  cross-tenant: a ceremony started under tenant A, continued with tenant
//       B's tenant_id, yields an undistinguished invalid_session — and
//       tenant_id was in the FORM BODY of that request
//   15  positive control: the same ceremony continued with tenant A's
//       tenant_id succeeds  (written BEFORE 14)
//   16  a mid-ceremony 401 carrying a rotated auth_session is a CONTINUATION,
//       not a failure — the single most important divergence from the TRD
//   17  a REJECTED factor (401 + rotated handle, no `next`) is also a
//       continuation, and carries no reason
//   18  attempt-cap exhaustion (400 invalid_session, no successor) is an
//       AoidError, so the flow can offer "start again"
//   19  a redirect_to_web with a missing/unusable authorization_url is a
//       failure, not a RedirectRequired carrying an unusable Uri
//       (50-04 deferred item 1, owner 50-08)

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../../auth/fixtures/fake_aoid_endpoint.dart';

void main() {
  late FakeAoidEndpoint fake;

  setUp(() {
    fake = FakeAoidEndpoint(issuer: kFakeAoidIssuer);
  });

  Future<http.Response> postForm(
    String path,
    Map<String, String> fields, {
    String contentType = 'application/x-www-form-urlencoded',
  }) => fake.client.post(
    Uri.parse('$kFakeAoidIssuer$path'),
    headers: {'content-type': contentType},
    body: fields,
  );

  group('fixture non-vacuity', () {
    test(
      'F1 the fake serves POST /oauth/native/start and mints a handle',
      () async {
        final res = await postForm('/oauth/native/start', {
          'client_id': kFakeNativeClientId,
          'tenant_id': kFakeTenantA,
          'redirect_uri': kFakeRedirectUri,
          'code_challenge': kFakeCodeChallenge,
          'code_challenge_method': 'S256',
        });

        expect(res.statusCode, 200);
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        expect(body['auth_session'], kFakeHandle1);
        expect(body['next'], 'password');
        expect(body['available_methods'], [
          'password',
          'webauthn_discoverable',
        ]);
        expect(fake.mintedNativeHandles, [kFakeHandle1]);
      },
    );

    test(
      'F2 the fake ROTATES the handle on every non-terminal verify',
      () async {
        fake.scriptNativeCeremony([
          const FakeNativeAdvance(next: 'mfa', availableMethods: ['totp']),
          const FakeNativeAdvance(next: 'mfa', availableMethods: ['totp']),
        ]);
        await postForm('/oauth/native/start', _startFields());

        final r1 = await postForm(
          '/oauth/native/verify',
          _verifyFields(authSession: kFakeHandle1, method: 'password'),
        );
        final h1 = (jsonDecode(r1.body) as Map)['auth_session'] as String;
        final r2 = await postForm(
          '/oauth/native/verify',
          _verifyFields(authSession: h1, method: 'totp'),
        );
        final h2 = (jsonDecode(r2.body) as Map)['auth_session'] as String;

        expect(h1, isNot(kFakeHandle1));
        expect(h2, isNot(h1));
        expect(fake.mintedNativeHandles, [kFakeHandle1, h1, h2]);
      },
    );

    test(
      'F3 replay, expiry, unknown handle and cross-tenant are BYTE-IDENTICAL '
      '— status, every header, and the raw body',
      () async {
        // Four independent ceremonies so each death mode is reached genuinely.
        Future<http.Response> deathMode(
          void Function(FakeAoidEndpoint f) arrange,
          Map<String, String> fields,
        ) async {
          final f = FakeAoidEndpoint(issuer: kFakeAoidIssuer);
          f.scriptNativeCeremony([
            const FakeNativeAdvance(next: 'mfa', availableMethods: ['totp']),
          ]);
          await f.client.post(
            Uri.parse('$kFakeAoidIssuer/oauth/native/start'),
            headers: {'content-type': 'application/x-www-form-urlencoded'},
            body: _startFields(),
          );
          arrange(f);
          return f.client.post(
            Uri.parse('$kFakeAoidIssuer/oauth/native/verify'),
            headers: {'content-type': 'application/x-www-form-urlencoded'},
            body: fields,
          );
        }

        // (a) REPLAY — present a handle that has already been consumed.
        final replay = await deathMode((f) async {
          await f.client.post(
            Uri.parse('$kFakeAoidIssuer/oauth/native/verify'),
            headers: {'content-type': 'application/x-www-form-urlencoded'},
            body: _verifyFields(authSession: kFakeHandle1, method: 'password'),
          );
        }, _verifyFields(authSession: kFakeHandle1, method: 'password'));

        // (b) EXPIRY.
        final expired = await deathMode(
          (f) => f.expireNativeCeremony(),
          _verifyFields(authSession: kFakeHandle1, method: 'password'),
        );

        // (c) UNKNOWN HANDLE.
        final unknown = await deathMode(
          (_) {},
          _verifyFields(
            authSession: 'native-handle-never-minted',
            method: 'password',
          ),
        );

        // (d) CROSS-TENANT — tenant B presenting tenant A's live handle.
        final crossTenant = await deathMode(
          (_) {},
          _verifyFields(
            authSession: kFakeHandle1,
            method: 'password',
            tenantId: kFakeTenantB,
          ),
        );

        String fingerprint(http.Response r) {
          final headers =
              r.headers.entries.map((e) => '${e.key}: ${e.value}').toList()
                ..sort();
          return '${r.statusCode}\n${headers.join('\n')}\n${r.body}';
        }

        final reference = fingerprint(replay);
        expect(
          fingerprint(expired),
          reference,
          reason: 'expiry must be indistinguishable from replay',
        );
        expect(
          fingerprint(unknown),
          reference,
          reason: 'an unknown handle must be indistinguishable from replay',
        );
        expect(
          fingerprint(crossTenant),
          reference,
          reason:
              'a cross-tenant presentation must be indistinguishable '
              'from replay — otherwise the endpoint is a membership oracle',
        );

        // And pin WHAT they agree on, so a mutation moving all four together
        // still fails (49-08 section 2's independent-assertion lesson).
        expect(replay.statusCode, 400);
        final decoded = jsonDecode(replay.body) as Map<String, dynamic>;
        expect(decoded.keys.toSet(), {'error', 'error_description'});
        expect(decoded['error'], 'invalid_session');
        expect(decoded['error_description'], 'invalid or expired auth_session');
      },
    );

    test(
      'F4 the fake rejects a JSON content-type, as 49-08 isFormContent does',
      () async {
        // A raw String body is required here: package:http REFUSES to encode a
        // Map body under a non-form content type (see F5). So this probe has to
        // construct the defect by hand.
        final res = await fake.client.post(
          Uri.parse('$kFakeAoidIssuer/oauth/native/start'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode(_startFields()),
        );
        expect(res.statusCode, 400);
        expect((jsonDecode(res.body) as Map)['error'], 'invalid_request');
      },
    );

    test('F5 package:http STRUCTURALLY refuses a Map body under a non-form '
        'content type — the anti-JSON rule is enforced by the library', () {
      // Recorded because it is load-bearing for 50-16's AODex adapter and for
      // any future maintainer tempted to "just send JSON": as long as the
      // client passes a Map<String,String> body, sending JSON is not a bug
      // that can be introduced quietly — it throws at the call site.
      expect(
        () => fake.client.post(
          Uri.parse('$kFakeAoidIssuer/oauth/native/start'),
          headers: {'content-type': 'application/json'},
          body: _startFields(),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'F6 the charset package:http appends still satisfies isFormContent',
      () async {
        // 49-08's isFormContent splits on ';' before comparing, so
        // "application/x-www-form-urlencoded; charset=utf-8" is accepted. This
        // matters: package:http's `body` setter APPENDS the charset, so the
        // client cannot send the bare media type even if it sets it bare.
        final res = await postForm(
          '/oauth/native/start',
          _startFields(),
          contentType: 'application/x-www-form-urlencoded; charset=utf-8',
        );
        expect(res.statusCode, 200);
      },
    );
  });
}

Map<String, String> _startFields() => {
  'client_id': kFakeNativeClientId,
  'tenant_id': kFakeTenantA,
  'redirect_uri': kFakeRedirectUri,
  'code_challenge': kFakeCodeChallenge,
  'code_challenge_method': 'S256',
};

Map<String, String> _verifyFields({
  required String authSession,
  required String method,
  String tenantId = kFakeTenantA,
  String clientId = kFakeNativeClientId,
  Map<String, String> extra = const {},
}) => {
  'auth_session': authSession,
  'client_id': clientId,
  'tenant_id': tenantId,
  'method': method,
  ...extra,
};
