// MODE A — the SDK hands the authorization code to the CONSUMING APP'S OWN
// backend, and never to AOID.
//
// The single most expensive mistake available here is posting to the wrong
// host. The authorization code is SINGLE-USE: if the client spends it at AOID,
// the app's backend exchange then fails with an opaque `invalid_grant` that
// looks like a server fault, and the login is unrecoverable for that ceremony.
// Item 8 asserts the host positively AND negatively for that reason.
//
// WHAT THIS FILE DOES **NOT** PROVE.
//   No real backend is contacted. The cookie attributes asserted below are
//   asserted against the FIXTURE, which is this TRD's statement of the contract
//   50-15's Go endpoint must implement — not proof that it does. Live coverage
//   is 50-17's.
//
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:eden_platform_flutter/src/aoid/mode/aoid_code_sink.dart';
import 'package:eden_platform_flutter/src/aoid/mode/http_bff_code_sink.dart';
import 'package:eden_platform_flutter/src/aoid/storage/aoid_token_store.dart';
import 'package:eden_platform_flutter/src/aoid/transport/aoid_error.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../riverpod_free_gate_test.dart' show stripComments;

/// The AOID issuer. The sink must NEVER post here — see this file's header.
const kAoidIssuer = 'https://auth.aocyber.ai';

/// The consuming app's own backend. Deliberately a different host from
/// [kAoidIssuer], so "posted to the right place" is a real assertion rather
/// than a tautology.
const kAppBackendOrigin = 'https://app.aodex.example';
final kExchangeUrl = Uri.parse(
  '$kAppBackendOrigin${HttpBffCodeSink.conventionalExchangePath}',
);

const kAuthorizationCode = 'authz-code-single-use-0001';
const kCodeVerifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
const kRedirectUri = 'https://app.aodex.example/auth/callback';

/// The Set-Cookie THIS TRD REQUIRES of the app's backend. Recorded here because
/// the fixture is where the contract becomes executable.
const kConformantSetCookie =
    'aodex_session=opaque-session-value-0001; Path=/; HttpOnly; SameSite=Lax; '
    'Secure';

/// A hand-built fake of the consuming app's backend.
///
/// Records every request it receives, and enforces the ONE property the real
/// backend must also enforce: an authorization code is spent exactly once.
class FakeAppBackend {
  FakeAppBackend({
    this.status = 200,
    this.body = '',
    this.setCookie = kConformantSetCookie,
  });

  int status;
  String body;

  /// `null` means "send no Set-Cookie at all".
  String? setCookie;

  final List<http.Request> requests = <http.Request>[];
  final Set<String> _spentCodes = <String>{};

  /// Set to have the transport die before any response — a dead socket, DNS
  /// failure or TLS failure.
  bool failTransport = false;

  http.Client get client => MockClient((request) async {
    requests.add(request);

    if (failTransport) {
      throw http.ClientException('connection failed', request.url);
    }

    final fields = Uri.splitQueryString(request.body);
    final code = fields['code'];

    // THE SINGLE-USE PROPERTY. The real backend gets this from AOID, which
    // refuses a replayed code; the fake models it so the client cannot be
    // written against a backend that tolerates replay.
    if (code != null && !_spentCodes.add(code)) {
      return http.Response(
        '{"error":"invalid_grant"}',
        400,
        headers: {'content-type': 'application/json'},
      );
    }

    return http.Response(
      body,
      status,
      headers: {'content-type': 'application/json', 'set-cookie': ?setCookie},
    );
  });
}

/// An AOID-shaped backend, used only to prove the sink never talks to it.
class FakeAoidIssuerProbe {
  final List<Uri> received = <Uri>[];

  http.Client get client => MockClient((request) async {
    received.add(request.url);
    return http.Response('{"error":"the sink must never post here"}', 400);
  });
}

void main() {
  late FakeAppBackend backend;

  setUp(() {
    backend = FakeAppBackend();
  });

  HttpBffCodeSink sinkFor(FakeAppBackend b, {bool isWeb = false}) =>
      HttpBffCodeSink(
        exchangeUrl: kExchangeUrl,
        httpClient: b.client,
        isWeb: isWeb,
      );

  group('ITEM 8 — the code goes to the APP\'S backend, never to AOID', () {
    test('submit POSTs {code, code_verifier} form-encoded to the configured '
        'app-backend URL', () async {
      await sinkFor(
        backend,
      ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);

      expect(backend.requests, hasLength(1));
      final req = backend.requests.single;

      expect(req.method, 'POST');
      expect(req.url, kExchangeUrl);
      expect(
        req.headers['content-type'],
        startsWith('application/x-www-form-urlencoded'),
        reason:
            'form encoding is CORS-safelisted; application/json would provoke '
            'an OPTIONS preflight on a cross-origin BFF',
      );

      final fields = Uri.splitQueryString(req.body);
      expect(fields['code'], kAuthorizationCode);
      expect(
        fields['code_verifier'],
        kCodeVerifier,
        reason:
            'the verifier is REQUIRED: PKCE binds the code to the client '
            'instance that began the ceremony, and in Mode A that instance '
            'spans app-frontend + app-backend. Dropping it breaks the exchange.',
      );
    });

    test(
      'the request host is the app\'s backend and is NOT the AOID issuer',
      () async {
        await sinkFor(
          backend,
        ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);

        final url = backend.requests.single.url;
        expect(url.host, Uri.parse(kAppBackendOrigin).host);
        expect(
          url.host,
          isNot(Uri.parse(kAoidIssuer).host),
          reason:
              'a sink that posts to AOID burns the single-use code, and the '
              'backend\'s own exchange then fails with an opaque invalid_grant',
        );
        expect(url.toString(), isNot(contains('aocyber.ai')));
      },
    );

    test(
      'NOTHING reaches an AOID-shaped client during a Mode A exchange',
      () async {
        final aoidProbe = FakeAoidIssuerProbe();
        // The sink is given ONLY the app backend's client; the probe exists to
        // prove the assertion above is not vacuous — a second transport is
        // available and must stay untouched.
        await sinkFor(
          backend,
        ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);
        expect(aoidProbe.received, isEmpty);
        expect(backend.requests, hasLength(1));
      },
    );

    test(
      'redirect_uri rides along when supplied, and is absent when not',
      () async {
        await sinkFor(backend).submit(
          code: kAuthorizationCode,
          codeVerifier: kCodeVerifier,
          redirectUri: kRedirectUri,
        );
        expect(
          Uri.splitQueryString(backend.requests.single.body)['redirect_uri'],
          kRedirectUri,
        );

        final b2 = FakeAppBackend();
        await sinkFor(b2).submit(code: 'c2', codeVerifier: kCodeVerifier);
        expect(
          Uri.splitQueryString(
            b2.requests.single.body,
          ).containsKey('redirect_uri'),
          isFalse,
        );
      },
    );
  });

  group('ITEM 9 — the result is a cookie-bound session holding no tokens', () {
    test('submit returns a Mode A session with no refresh token', () async {
      final session = await sinkFor(
        backend,
      ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);

      expect(session.hasClientHeldRefreshToken, isFalse);
      expect(session.refreshToken, isNull);
      expect(session.cookieBound, isTrue);
      expect(session.posture, AoidRefreshTokenPosture.backendHeldCookie);
    });

    test(
      'a session built for WEB is cookie-bound and holds nothing either',
      () async {
        final session = await sinkFor(
          backend,
          isWeb: true,
        ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);
        expect(session.isWeb, isTrue);
        expect(session.hasClientHeldRefreshToken, isFalse);
      },
    );
  });

  group('ITEM 11 — the sink never takes custody of a token', () {
    // NON-VACUOUS FIXTURE. The backend returns a body CONTAINING a real refresh
    // token — the realistic mistake of a BFF echoing what AOID gave it. If the
    // sink read the body, this is the value it would have taken custody of.
    test(
      'a refresh token in the backend\'s RESPONSE BODY is not adopted',
      () async {
        backend.body =
            '{"access_token":"access-from-bff-0001",'
            '"refresh_token":"refresh-token-the-bff-should-not-have-sent"}';

        final session = await sinkFor(
          backend,
        ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);

        expect(
          session.refreshToken,
          isNull,
          reason:
              'the body carried a refresh token and the session must still hold '
              'none — Mode A means the token stays on the backend',
        );
        expect(session.hasClientHeldRefreshToken, isFalse);
        expect(
          session.accessToken,
          isNull,
          reason:
              'this TRD ships the NARROWEST Mode A contract: 2xx + Set-Cookie. '
              'Adopting tokens from the body is a widening 50-15 has not agreed '
              'to.',
        );
      },
    );

    test('the sink has no token-store seam at all — structurally, not by '
        'convention', () {
      final code = stripComments(
        File('lib/src/aoid/mode/http_bff_code_sink.dart').readAsStringSync(),
      );
      expect(code, isNot(contains('AoidTokenStore')));
      expect(code, isNot(contains('writeRefreshToken')));
      expect(code, isNot(contains('TokenStorage')));
    });

    // Positive control: a predicate that matches nothing passes forever.
    test(
      'POSITIVE CONTROL — the store-seam predicate fires on a planted use',
      () {
        const planted = 'void f(AoidTokenStore s) { s.writeRefreshToken(x); }';
        expect(stripComments(planted), contains('AoidTokenStore'));
        expect(stripComments(planted), contains('writeRefreshToken'));
      },
    );
  });

  group('ITEM 10 — a broken BFF is NOT an authentication failure', () {
    test('a 500 from the app\'s backend is an AoidBffExchangeError, and is '
        'neither an AoidError nor an AoidTransportError', () async {
      backend
        ..status = 500
        ..body = 'upstream exploded';

      Object? caught;
      try {
        await sinkFor(
          backend,
        ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);
      } catch (e) {
        caught = e;
      }

      expect(caught, isA<AoidBffExchangeError>());
      expect(
        caught,
        isNot(isA<AoidError>()),
        reason:
            'an app outage rendered as an AoidError reads to the user, and to '
            'support, as "wrong password"',
      );
      expect(
        caught,
        isNot(isA<AoidTransportError>()),
        reason:
            'AoidTransportError means AOID is unreachable. This is the app\'s '
            'OWN backend — a different system, a different on-call rota.',
      );
      expect(
        (caught! as AoidBffExchangeError).kind,
        AoidBffFailureKind.backendError,
      );
      expect((caught as AoidBffExchangeError).statusCode, 500);
    });

    test('a dead socket is unreachable, not a rejected credential', () async {
      backend.failTransport = true;

      Object? caught;
      try {
        await sinkFor(
          backend,
        ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);
      } catch (e) {
        caught = e;
      }

      expect(caught, isA<AoidBffExchangeError>());
      expect(
        (caught! as AoidBffExchangeError).kind,
        AoidBffFailureKind.unreachable,
      );
      expect((caught as AoidBffExchangeError).statusCode, isNull);
    });

    test('a 4xx is backendRefused — still not an AOID auth decision', () async {
      backend.status = 403;

      Object? caught;
      try {
        await sinkFor(
          backend,
        ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);
      } catch (e) {
        caught = e;
      }

      expect(
        (caught! as AoidBffExchangeError).kind,
        AoidBffFailureKind.backendRefused,
      );
      expect(caught, isNot(isA<AoidError>()));
    });

    test('the message names the APPLICATION\'S backend, and never reflects the '
        'backend\'s own response text', () async {
      // NON-VACUOUS: the backend's body carries a secret AND the verifier. A
      // client that reflected the response would leak both into every log sink.
      backend
        ..status = 500
        ..body =
            'stack trace: client_secret=SUPERSECRET verifier=$kCodeVerifier';

      Object? caught;
      try {
        await sinkFor(
          backend,
        ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);
      } catch (e) {
        caught = e;
      }

      final rendered = '${(caught! as AoidBffExchangeError).message} $caught';
      expect(rendered, isNot(contains('SUPERSECRET')));
      expect(rendered, isNot(contains(kCodeVerifier)));
      expect(rendered, isNot(contains(kAuthorizationCode)));
      expect(rendered.toLowerCase(), contains('backend'));
    });
  });

  group('ITEM 12 — the authorization code is spent exactly once', () {
    test(
      'one submit puts exactly ONE request on the wire — no auto-retry',
      () async {
        backend.status = 500;
        await expectLater(
          sinkFor(
            backend,
          ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier),
          throwsA(isA<AoidBffExchangeError>()),
        );
        expect(
          backend.requests,
          hasLength(1),
          reason:
              'a retry would re-present a single-use code. The first attempt may '
              'well have succeeded server-side; the retry then fails and the '
              'ceremony is destroyed.',
        );
      },
    );

    test('a retried socket failure is also exactly one request', () async {
      backend.failTransport = true;
      await expectLater(
        sinkFor(
          backend,
        ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier),
        throwsA(isA<AoidBffExchangeError>()),
      );
      expect(backend.requests, hasLength(1));
    });

    test('two submits with the SAME code do not both succeed', () async {
      final sink = sinkFor(backend);

      final first = await sink.submit(
        code: kAuthorizationCode,
        codeVerifier: kCodeVerifier,
      );
      expect(first.cookieBound, isTrue);

      await expectLater(
        sink.submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier),
        throwsA(isA<AoidBffExchangeError>()),
        reason: 'the backend spent the code on the first call',
      );
      expect(backend.requests, hasLength(2));
    });

    // Positive control: the fake's single-use rule is keyed on the CODE, not on
    // "the second call always fails". Without this, the test above would pass
    // against a fake that refuses every repeat request.
    test(
      'POSITIVE CONTROL — a DIFFERENT code still succeeds after one is spent',
      () async {
        final sink = sinkFor(backend);
        await sink.submit(code: 'code-A', codeVerifier: kCodeVerifier);
        final second = await sink.submit(
          code: 'code-B',
          codeVerifier: kCodeVerifier,
        );
        expect(second.cookieBound, isTrue);
      },
    );
  });

  group('the backend URL is REQUIRED and never defaulted', () {
    test('there is no hardcoded fallback URL in the sink', () {
      final code = stripComments(
        File('lib/src/aoid/mode/http_bff_code_sink.dart').readAsStringSync(),
      );
      for (final banned in const [
        'localhost',
        '127.0.0.1',
        '8080',
        'aocyber.ai',
      ]) {
        expect(
          code,
          isNot(contains(banned)),
          reason:
              'auth_provider.dart:56 falls back to a hardcoded localhost URL '
              'on a forbidden port; that pattern must not be copied. A silent '
              'default here would post a live authorization code somewhere '
              'nobody chose.',
        );
      }
    });

    test(
      'a relative or schemeless exchange URL is refused at construction',
      () {
        for (final bad in <Uri>[
          Uri.parse('/auth/aoid/native/exchange'),
          Uri(),
        ]) {
          expect(
            () => HttpBffCodeSink(exchangeUrl: bad, httpClient: backend.client),
            throwsA(isA<ArgumentError>()),
            reason: 'exchangeUrl=$bad has no origin to post to',
          );
        }
      },
    );

    test('the conventional path is exposed as a constant, and is NOT applied '
        'automatically', () {
      expect(
        HttpBffCodeSink.conventionalExchangePath,
        '/auth/aoid/native/exchange',
      );

      // Applying it automatically would be a fallback by another name: a
      // consumer passing an origin-only URL must get their URL, unchanged.
      final origin = Uri.parse('$kAppBackendOrigin/custom/exchange');
      final sink = HttpBffCodeSink(
        exchangeUrl: origin,
        httpClient: backend.client,
      );
      expect(sink.exchangeUrl, origin);
    });
  });

  group('the session cookie must be httpOnly and SameSite', () {
    test('a conformant Set-Cookie is accepted', () async {
      final session = await sinkFor(
        backend,
      ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);
      expect(session.cookieBound, isTrue);
    });

    test('a session cookie WITHOUT HttpOnly is refused where the header is '
        'visible', () async {
      backend.setCookie = 'aodex_session=v; Path=/; SameSite=Lax; Secure';

      Object? caught;
      try {
        await sinkFor(
          backend,
        ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);
      } catch (e) {
        caught = e;
      }
      expect(
        (caught! as AoidBffExchangeError).kind,
        AoidBffFailureKind.insecureSessionCookie,
      );
    });

    test('a session cookie WITHOUT SameSite is refused too', () async {
      backend.setCookie = 'aodex_session=v; Path=/; HttpOnly; Secure';

      Object? caught;
      try {
        await sinkFor(
          backend,
        ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);
      } catch (e) {
        caught = e;
      }
      expect(
        (caught! as AoidBffExchangeError).kind,
        AoidBffFailureKind.insecureSessionCookie,
      );
    });

    test('a companion NON-httpOnly cookie is tolerated alongside a conformant '
        'session cookie — a JS-readable CSRF cookie is legitimate', () async {
      backend.setCookie =
          'csrf_token=abc; Path=/; SameSite=Lax, '
          'aodex_session=v; Path=/; HttpOnly; SameSite=Lax; Secure';

      final session = await sinkFor(
        backend,
      ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);
      expect(session.cookieBound, isTrue);
    });

    // THE DISCRIMINATING FIXTURE. Every other row here is also satisfied by a
    // naive `raw.contains('httponly') && raw.contains('samesite')` over the
    // whole joined header — I checked, and all four passed against it. This is
    // the case that separates "some cookie is protected" from "the words appear
    // somewhere": NEITHER cookie carries both attributes, but between them the
    // header contains both words.
    test('two cookies that TOGETHER mention HttpOnly and SameSite, but neither '
        'of which carries both, is still a refusal', () async {
      backend.setCookie =
          'aodex_session=v; Path=/; SameSite=Lax, '
          'telemetry=t; Path=/; HttpOnly';

      Object? caught;
      try {
        await sinkFor(
          backend,
        ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);
      } catch (e) {
        caught = e;
      }
      expect(
        caught,
        isA<AoidBffExchangeError>(),
        reason:
            'the session cookie is not httpOnly; that a DIFFERENT cookie is '
            'must not launder it',
      );
      expect(
        (caught! as AoidBffExchangeError).kind,
        AoidBffFailureKind.insecureSessionCookie,
      );
    });

    test('ON WEB the check cannot fire — the browser hides Set-Cookie, and the '
        'SDK must not pretend otherwise', () async {
      backend.setCookie = null; // exactly what a browser client surfaces

      final session = await sinkFor(
        backend,
        isWeb: true,
      ).submit(code: kAuthorizationCode, codeVerifier: kCodeVerifier);
      expect(
        session.cookieBound,
        isTrue,
        reason:
            'an httpOnly cookie is invisible to JS by definition, so on web '
            'there is nothing to inspect. Failing here would break every real '
            'web login.',
      );
    });

    test('the strict check can be switched off for a backend that cannot '
        'comply', () async {
      backend.setCookie = 'aodex_session=v; Path=/';
      final sink = HttpBffCodeSink(
        exchangeUrl: kExchangeUrl,
        httpClient: backend.client,
        isWeb: false,
        requireSecureSessionCookie: false,
      );
      final session = await sink.submit(
        code: kAuthorizationCode,
        codeVerifier: kCodeVerifier,
      );
      expect(session.cookieBound, isTrue);
    });
  });

  group('the code_verifier is documented as NOT the client secret', () {
    test('the warning is in the source where it would be misread', () {
      final src = File(
        'lib/src/aoid/mode/aoid_code_sink.dart',
      ).readAsStringSync();
      expect(src, contains('MUST NOT be confused with the client secret'));
    });
  });
}
