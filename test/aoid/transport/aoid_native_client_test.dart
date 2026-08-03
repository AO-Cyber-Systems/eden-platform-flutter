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

import 'package:eden_platform_flutter/aoid.dart';
import 'package:eden_platform_flutter/eden_platform.dart' show RedirectRequired;
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

  // =========================================================================
  // AoidNativeClient — test-list items 1..19
  // =========================================================================

  group('AoidNativeClient', () {
    late AoidNativeClient client;

    setUp(() {
      client = AoidNativeClient(
        endpoints: AoidEndpoints.parse(kFakeAoidIssuer),
        httpClient: fake.client,
      );
    });

    Future<AoidNativeResponse> startCeremony() => client.start(
      clientId: kFakeNativeClientId,
      tenantId: kFakeTenantA,
      redirectUri: kFakeRedirectUri,
      codeChallenge: kFakeCodeChallenge,
    );

    test(
      '1 start() POSTs form-encoded to /oauth/native/start with client_id and '
      'tenant_id IN THE BODY, and parses the response',
      () async {
        final res = await client.start(
          clientId: kFakeNativeClientId,
          tenantId: kFakeTenantA,
          redirectUri: kFakeRedirectUri,
          codeChallenge: kFakeCodeChallenge,
          scopes: const ['openid', 'profile', 'email'],
          nonce: 'fixture-nonce-01',
          activeTenant: const AoidActiveTenantSlug('acme-eu'),
          loginHint: 'someone@alpha.test',
        );

        final req = fake.nativeRequests.single;
        expect(req.path, '/oauth/native/start');
        expect(req.fields['client_id'], kFakeNativeClientId);
        expect(req.fields['tenant_id'], kFakeTenantA);
        expect(req.fields['redirect_uri'], kFakeRedirectUri);
        expect(req.fields['code_challenge'], kFakeCodeChallenge);
        expect(req.fields['code_challenge_method'], 'S256');
        // RFC 6749 §3.3: SPACE-delimited, and 49-08 splits on space.
        expect(req.fields['scope'], 'openid profile email');
        expect(req.fields['nonce'], 'fixture-nonce-01');
        // The ACTIVE tenant SLUG rides on `tenant`, mirroring /oauth/authorize
        // — NOT on `tenant_id`, which is the UUID. Conflating them is D5's trap.
        expect(req.fields['tenant'], 'acme-eu');
        expect(req.fields['login_hint'], 'someone@alpha.test');

        final cont = res as AoidNativeContinue;
        expect(cont.authSession, kFakeHandle1);
        expect(cont.next, 'password');
        expect(cont.availableMethods, ['password', 'webauthn_discoverable']);
      },
    );

    test('2 start() sends NO application header other than the content type — '
        'the CORS simple-request guard', () async {
      await startCeremony();
      // THE assertion. 49-08 built a per-client origin allowlist that only
      // works because these are CORS SIMPLE requests: a preflight is an
      // OPTIONS with no body, so client_id would be unresolvable. ONE custom
      // header turns every browser caller into a preflighted one.
      expect(fake.nativeRequests.single.headers.keys.toSet(), {'content-type'});
    });

    test('3 the content type is form-urlencoded, never JSON', () async {
      await startCeremony();
      final ct = fake.nativeRequests.single.headers['content-type']!;
      expect(ct.split(';').first.trim(), 'application/x-www-form-urlencoded');
      expect(ct, isNot(contains('json')));
    });

    test('4 verify() POSTs the full field set form-encoded', () async {
      fake.scriptNativeCeremony([
        const FakeNativeTerminal('auth-code-fixture'),
      ]);
      await startCeremony();
      await client.verify(
        authSession: kFakeHandle1,
        clientId: kFakeNativeClientId,
        tenantId: kFakeTenantA,
        method: 'password',
        factorFields: const {
          'email': 'someone@alpha.test',
          'password': 'correct horse battery staple',
        },
      );

      final req = fake.nativeRequests.last;
      expect(req.path, '/oauth/native/verify');
      expect(req.headers.keys.toSet(), {'content-type'});
      expect(req.fields, {
        'auth_session': kFakeHandle1,
        'client_id': kFakeNativeClientId,
        'tenant_id': kFakeTenantA,
        'method': 'password',
        'email': 'someone@alpha.test',
        'password': 'correct horse battery staple',
      });
    });

    test(
      '5 a terminal verify() yields the authorization code — the wire key is '
      'authorization_code, NOT code',
      () async {
        fake.scriptNativeCeremony([
          const FakeNativeTerminal('auth-code-fixture'),
        ]);
        await startCeremony();
        final res = await client.verify(
          authSession: kFakeHandle1,
          clientId: kFakeNativeClientId,
          tenantId: kFakeTenantA,
          method: 'password',
        );
        expect((res as AoidNativeCode).authorizationCode, 'auth-code-fixture');
      },
    );

    test(
      '6 the handle ROTATES: two sequential verify() calls send two DIFFERENT '
      'auth_session values, the second being the first response\'s',
      () async {
        fake.scriptNativeCeremony([
          const FakeNativeAdvance(next: 'mfa', availableMethods: ['totp']),
          const FakeNativeTerminal('auth-code-fixture'),
        ]);
        await startCeremony();

        final step1 =
            await client.verify(
                  authSession: kFakeHandle1,
                  clientId: kFakeNativeClientId,
                  tenantId: kFakeTenantA,
                  method: 'password',
                )
                as AoidNativeContinue;

        await client.verify(
          authSession: step1.authSession,
          clientId: kFakeNativeClientId,
          tenantId: kFakeTenantA,
          method: 'totp',
          factorFields: const {'otp': '123456'},
        );

        // Asserted on the RECORDED REQUEST BODIES, not on a successful login —
        // a login can succeed for the wrong reason.
        final verifies = fake.nativeRequests
            .where((r) => r.path.endsWith('/verify'))
            .toList();
        expect(verifies, hasLength(2));
        expect(verifies[0].fields['auth_session'], kFakeHandle1);
        expect(verifies[1].fields['auth_session'], step1.authSession);
        expect(
          verifies[1].fields['auth_session'],
          isNot(verifies[0].fields['auth_session']),
          reason:
              'a client that caches the handle from start fails at step two',
        );
      },
    );

    test(
      '7 invalid_session yields AoidError with code invalidSession',
      () async {
        fake.scriptNativeCeremony([const FakeNativeAdvance(next: 'mfa')]);
        await startCeremony();
        await expectLater(
          client.verify(
            authSession: 'native-handle-never-minted',
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
      '8 the error surface does not distinguish replay from expiry from '
      'unknown handle from cross-tenant — same code AND same message',
      () async {
        Future<AoidError> death(
          Future<void> Function(FakeAoidEndpoint f, AoidNativeClient c) drive,
        ) async {
          final f = FakeAoidEndpoint(issuer: kFakeAoidIssuer);
          f.scriptNativeCeremony([const FakeNativeAdvance(next: 'mfa')]);
          final c = AoidNativeClient(
            endpoints: AoidEndpoints.parse(kFakeAoidIssuer),
            httpClient: f.client,
          );
          await c.start(
            clientId: kFakeNativeClientId,
            tenantId: kFakeTenantA,
            redirectUri: kFakeRedirectUri,
            codeChallenge: kFakeCodeChallenge,
          );
          try {
            await drive(f, c);
            fail('expected an AoidError');
          } on AoidError catch (e) {
            return e;
          }
        }

        final replay = await death((f, c) async {
          await c.verify(
            authSession: kFakeHandle1,
            clientId: kFakeNativeClientId,
            tenantId: kFakeTenantA,
            method: 'password',
          );
          await c.verify(
            authSession: kFakeHandle1,
            clientId: kFakeNativeClientId,
            tenantId: kFakeTenantA,
            method: 'password',
          );
        });
        final expired = await death((f, c) async {
          f.expireNativeCeremony();
          await c.verify(
            authSession: kFakeHandle1,
            clientId: kFakeNativeClientId,
            tenantId: kFakeTenantA,
            method: 'password',
          );
        });
        final unknown = await death(
          (f, c) => c.verify(
            authSession: 'native-handle-never-minted',
            clientId: kFakeNativeClientId,
            tenantId: kFakeTenantA,
            method: 'password',
          ),
        );
        final crossTenant = await death(
          (f, c) => c.verify(
            authSession: kFakeHandle1,
            clientId: kFakeNativeClientId,
            tenantId: kFakeTenantB,
            method: 'password',
          ),
        );

        for (final other in [expired, unknown, crossTenant]) {
          expect(other.code, replay.code);
          expect(other.message, replay.message);
          expect(other.toString(), replay.toString());
        }
        // Pin WHAT they agree on, so a mutation moving all four together still
        // fails (49-08 section 2's independent-assertion lesson).
        expect(replay.code, AoidErrorCode.invalidSession);
      },
    );

    test(
      '9 redirect_to_web maps to 50-04 RedirectRequired, not to a failure',
      () async {
        fake.scriptNativeCeremony([const FakeNativeRedirect()]);
        await startCeremony();
        final res = await client.verify(
          authSession: kFakeHandle1,
          clientId: kFakeNativeClientId,
          tenantId: kFakeTenantA,
          method: 'federated',
        );

        final redirect = res as AoidNativeRedirect;
        expect(redirect.result, isA<RedirectRequired>());
        expect(
          redirect.result.authorizationUrl,
          Uri.parse(kFakeAuthorizationUrl),
        );
        // TELEMETRY ONLY — never UI copy. Carries the wire code, nothing more.
        expect(redirect.result.reason, 'redirect_to_web');
      },
    );

    test('10 invalid_client and invalid_request map to their codes', () async {
      Future<AoidError> errorFor(FakeNativeStep step) async {
        final f = FakeAoidEndpoint(issuer: kFakeAoidIssuer);
        f.scriptNativeCeremony([step]);
        final c = AoidNativeClient(
          endpoints: AoidEndpoints.parse(kFakeAoidIssuer),
          httpClient: f.client,
        );
        await c.start(
          clientId: kFakeNativeClientId,
          tenantId: kFakeTenantA,
          redirectUri: kFakeRedirectUri,
          codeChallenge: kFakeCodeChallenge,
        );
        try {
          await c.verify(
            authSession: kFakeHandle1,
            clientId: kFakeNativeClientId,
            tenantId: kFakeTenantA,
            method: 'password',
          );
          fail('expected an AoidError');
        } on AoidError catch (e) {
          return e;
        }
      }

      expect(
        (await errorFor(
          const FakeNativeErrorStep(
            code: 'invalid_client',
            description: 'client not found',
            status: 400,
          ),
        )).code,
        AoidErrorCode.invalidClient,
      );
      expect(
        (await errorFor(
          const FakeNativeErrorStep(
            code: 'invalid_request',
            description: 'invalid request',
            status: 400,
          ),
        )).code,
        AoidErrorCode.invalidRequest,
      );
    });

    test('11 no secret in any message — not the password, the TOTP code, the '
        'email, nor the auth_session', () async {
      const password = 'PLAINTEXT-PASSWORD-MUST-NOT-LEAK';
      const otp = '867530';
      const email = 'leak-probe@alpha.test';
      fake.scriptNativeCeremony([
        const FakeNativeErrorStep(
          code: 'invalid_client',
          description: 'client not found',
          status: 400,
        ),
      ]);
      await startCeremony();

      Object? thrown;
      try {
        await client.verify(
          authSession: kFakeHandle1,
          clientId: kFakeNativeClientId,
          tenantId: kFakeTenantA,
          method: 'password',
          factorFields: const {
            'email': email,
            'password': password,
            'otp': otp,
          },
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<AoidError>());
      final rendered = '${thrown!}${(thrown as AoidError).message}';
      for (final secret in const [password, otp, email, kFakeHandle1]) {
        expect(
          rendered,
          isNot(contains(secret)),
          reason: 'request input must never be interpolated into an error',
        );
      }
    });

    test(
      '12 a transport failure is a DIFFERENT type from an auth failure, so a '
      'blip cannot be turned into a sign-out',
      () async {
        Future<Object> thrownFor(FakeNativeStep step) async {
          final f = FakeAoidEndpoint(issuer: kFakeAoidIssuer);
          f.scriptNativeCeremony([step]);
          final c = AoidNativeClient(
            endpoints: AoidEndpoints.parse(kFakeAoidIssuer),
            httpClient: f.client,
          );
          await c.start(
            clientId: kFakeNativeClientId,
            tenantId: kFakeTenantA,
            redirectUri: kFakeRedirectUri,
            codeChallenge: kFakeCodeChallenge,
          );
          try {
            await c.verify(
              authSession: kFakeHandle1,
              clientId: kFakeNativeClientId,
              tenantId: kFakeTenantA,
              method: 'password',
            );
            fail('expected a throw');
          } catch (e) {
            return e;
          }
        }

        final socket = await thrownFor(const FakeNativeNetworkFailure());
        final serverError = await thrownFor(const FakeNativeServerError());
        final unavailable = await thrownFor(const FakeNativeUnavailable());

        for (final e in [socket, serverError, unavailable]) {
          expect(
            e,
            isA<AoidTransportError>(),
            reason:
                'AoidOidcAuthStrategy.restoreSession swallows every '
                'non-200 as null, so a 500 signs the user out. Not repeated.',
          );
          expect(e, isNot(isA<AoidError>()));
        }
        expect(
          (unavailable as AoidTransportError).retryAfterSeconds,
          30,
          reason: '49-08 answers a replica with 503 + Retry-After',
        );
      },
    );

    test(
      '13 available_methods absent is an empty list, not an error',
      () async {
        fake.startAvailableMethods = null;
        final res = await startCeremony();
        expect((res as AoidNativeContinue).availableMethods, isEmpty);
      },
    );

    test(
      '15 POSITIVE CONTROL: the ceremony continued with tenant A succeeds',
      () async {
        fake.scriptNativeCeremony([
          const FakeNativeAdvance(next: 'mfa', availableMethods: ['totp']),
        ]);
        await startCeremony();
        final res = await client.verify(
          authSession: kFakeHandle1,
          clientId: kFakeNativeClientId,
          tenantId: kFakeTenantA,
          method: 'password',
        );
        expect(res, isA<AoidNativeContinue>());
        expect(
          fake.nativeRequests.last.fields['tenant_id'],
          kFakeTenantA,
          reason: 'tenant_id must be in the FORM BODY on every step',
        );
      },
    );

    test(
      '14 cross-tenant: a ceremony started under tenant A and continued with '
      'tenant B yields an undistinguished invalid_session',
      () async {
        fake.scriptNativeCeremony([
          const FakeNativeAdvance(next: 'mfa', availableMethods: ['totp']),
        ]);
        await startCeremony();

        Object? thrown;
        try {
          await client.verify(
            authSession: kFakeHandle1,
            clientId: kFakeNativeClientId,
            tenantId: kFakeTenantB,
            method: 'password',
          );
        } catch (e) {
          thrown = e;
        }

        expect(thrown, isA<AoidError>());
        expect((thrown! as AoidError).code, AoidErrorCode.invalidSession);
        // Both halves: the refusal AND that tenant_id travelled in the BODY.
        final req = fake.nativeRequests.last;
        expect(req.fields['tenant_id'], kFakeTenantB);
        expect(req.headers.keys.toSet(), {'content-type'});
        expect(
          req.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('x-aoid-tenant')),
        );
      },
    );

    test('16 a mid-ceremony 401 carrying a rotated auth_session is a '
        'CONTINUATION, not a failure', () async {
      fake.scriptNativeCeremony([
        const FakeNativeAdvance(
          next: 'mfa',
          availableMethods: ['totp', 'backup_code'],
        ),
      ]);
      await startCeremony();
      final res = await client.verify(
        authSession: kFakeHandle1,
        clientId: kFakeNativeClientId,
        tenantId: kFakeTenantA,
        method: 'password',
      );

      final cont = res as AoidNativeContinue;
      expect(cont.advanced, isTrue);
      expect(cont.next, 'mfa');
      expect(cont.availableMethods, ['totp', 'backup_code']);
      expect(cont.authSession, isNot(kFakeHandle1));
    });

    test('17 a REJECTED factor (401 + rotated handle, no next) is ALSO a '
        'continuation, and carries no reason', () async {
      fake.scriptNativeCeremony([const FakeNativeReject()]);
      await startCeremony();
      final res = await client.verify(
        authSession: kFakeHandle1,
        clientId: kFakeNativeClientId,
        tenantId: kFakeTenantA,
        method: 'password',
      );

      final cont = res as AoidNativeContinue;
      // 49-06: a wrong password costs ONE attempt and yields a fresh handle.
      // Returning Failed here would clear the continuation token and destroy
      // a recoverable ceremony (50-04 deferred item 2, owner 50-08).
      expect(cont.advanced, isFalse);
      expect(cont.next, isEmpty);
      expect(cont.availableMethods, isEmpty);
      expect(cont.authSession, isNot(kFakeHandle1));
    });

    test(
      '18 attempt-cap exhaustion is an AoidError(invalidSession) so the flow '
      'can offer "start again"',
      () async {
        fake.scriptNativeCeremony([const FakeNativeAttemptCapExceeded()]);
        await startCeremony();
        await expectLater(
          client.verify(
            authSession: kFakeHandle1,
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
      '19 a redirect_to_web with an unusable authorization_url is a failure, '
      'not a RedirectRequired carrying an unusable Uri',
      () async {
        // 50-04 deferred item 1, owner 50-08: RedirectRequired cannot prevent
        // an empty/relative Uri, so the notifier would sit in `refreshing`
        // with nothing to open and no error ever surfacing.
        fake.scriptNativeCeremony([
          const FakeNativeRedirect(authorizationUrl: ''),
        ]);
        await startCeremony();
        await expectLater(
          client.verify(
            authSession: kFakeHandle1,
            clientId: kFakeNativeClientId,
            tenantId: kFakeTenantA,
            method: 'federated',
          ),
          throwsA(isA<AoidError>()),
        );
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
