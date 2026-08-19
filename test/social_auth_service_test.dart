// Tests for the AUTHORIZATION-CODE social login flow.
//
// AOID, the spec (SDK-08 / D6). This file previously asserted the
// opposite contract — that `sessionFromCallbackUrl` parsed `access_token` and
// `refresh_token` out of the callback query string. That contract was the
// vulnerability. eden-platform-go stopped the server sending tokens;
// these tests pin the client to the replacement.
//
// Wire contract consumed VERBATIM from 50-the design notes:
//   callback: <redirect_uri>?code=<handoff>&state=<state>
//   exchange: POST /auth/social/exchange
//              Content-Type: application/x-www-form-urlencoded
//              code=<handoff>&redirect_uri=<exact target the code was minted for>
//   success: 200 application/json {"access_token":"...","refresh_token":"..."}
//   failure: 400 text/plain "invalid request"  (GET -> 405)

import 'dart:convert';

import 'package:eden_platform_flutter/src/auth/social_auth_service.dart';
import 'package:eden_platform_flutter/src/errors/platform_errors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _scheme = 'com.example.testapp';
const _redirectUri = 'com.example.testapp://auth/social/callback';
const _baseUrl = 'https://api.example.test';

/// Records every request the service makes so a test can assert that NO
/// request was made (item 8) rather than merely that an error was thrown.
class _Recorder {
  final List<http.Request> requests = [];

  MockClient client(Future<http.Response> Function(http.Request) handler) {
    return MockClient((request) async {
      requests.add(request);
      return handler(request);
    });
  }

  MockClient okClient({
    String access = 'acc-from-body',
    String refresh = 'ref-from-body',
  }) {
    return client(
      (_) async => http.Response(
        jsonEncode({'access_token': access, 'refresh_token': refresh}),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
  }
}

SocialAuthService _service(http.Client client, {String scheme = _scheme}) {
  return SocialAuthService(
    repository: null,
    baseUrl: _baseUrl,
    callbackScheme: scheme,
    httpClient: client,
  );
}

void main() {
  group('SocialAuthService.redirectUriFor', () {
    test('web → \${origin}/auth.html (unchanged — item 11)', () {
      final uri = SocialAuthService.redirectUriFor(
        isWeb: true,
        webOrigin: 'https://app.justindonnaruma.us',
        callbackScheme: _scheme,
      );
      expect(uri, 'https://app.justindonnaruma.us/auth.html');
    });

    test('mobile → uses the CONFIGURED scheme, not a hardcoded bundle id', () {
      final uri = SocialAuthService.redirectUriFor(
        isWeb: false,
        webOrigin: 'https://ignored.example',
        callbackScheme: 'ai.aocyber.someotherapp',
      );
      expect(uri, 'ai.aocyber.someotherapp://auth/social/callback');
      expect(uri, isNot(contains('justindonnaruma')));
    });

    test('web with an empty origin fails fast rather than yielding a relative '
        'URI that AOID would reject as invalid_request', () {
      expect(
        () => SocialAuthService.redirectUriFor(
          isWeb: true,
          webOrigin: '',
          callbackScheme: _scheme,
        ),
        throwsA(isA<AuthError>()),
      );
    });
  });

  group('callback scheme is required configuration (item 10)', () {
    test('empty scheme throws a fail-fast error naming the setting', () {
      expect(
        () => SocialAuthService(
          repository: null,
          baseUrl: _baseUrl,
          callbackScheme: '',
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('callbackScheme'),
              contains('SOCIAL_CALLBACK_SCHEME'),
            ),
          ),
        ),
      );
    });

    test('a scheme containing :// is rejected — it is a scheme, not a URI', () {
      expect(
        () => SocialAuthService(
          repository: null,
          baseUrl: _baseUrl,
          callbackScheme: 'com.example.app://auth',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('parseCallbackUrl', () {
    test('reads ?code= and ?state=', () {
      final parsed = SocialAuthService.parseCallbackUrl(
        '$_redirectUri?code=HANDOFF123&state=STATE456',
      );
      expect(parsed.code, 'HANDOFF123');
      expect(parsed.state, 'STATE456');
    });

    test('IGNORES access_token/refresh_token a stale backend still appends '
        '(item 5 — the leak must not survive the rollout window)', () {
      final parsed = SocialAuthService.parseCallbackUrl(
        '$_redirectUri?code=HANDOFF123&state=STATE456'
        '&access_token=LEAKED_ACCESS&refresh_token=LEAKED_REFRESH',
      );
      expect(parsed.code, 'HANDOFF123');
      // The parsed result exposes no token field at all — there is nothing for
      // a caller to opportunistically use.
      expect(parsed.toString(), isNot(contains('LEAKED_ACCESS')));
      expect(parsed.toString(), isNot(contains('LEAKED_REFRESH')));
    });

    test('an ?error= param surfaces as an AuthError', () {
      expect(
        () => SocialAuthService.parseCallbackUrl(
          '$_redirectUri?error=access_denied',
        ),
        throwsA(isA<AuthError>()),
      );
    });

    test('a callback carrying ONLY tokens (no code) is refused — it does not '
        'silently succeed', () {
      expect(
        () => SocialAuthService.parseCallbackUrl(
          '$_redirectUri?access_token=LEAKED&refresh_token=LEAKED2',
        ),
        throwsA(isA<AuthError>()),
      );
    });
  });

  group('completeCallback — exchange (items 6, 7)', () {
    test(
      'POSTs code + redirect_uri form-encoded to /auth/social/exchange',
      () async {
        final rec = _Recorder();
        final svc = _service(rec.okClient());

        await svc.completeCallback(
          callbackUrl: '$_redirectUri?code=HANDOFF123&state=STATE456',
          redirectUri: _redirectUri,
          expectedState: 'STATE456',
        );

        expect(rec.requests, hasLength(1));
        final req = rec.requests.single;
        expect(req.method, 'POST');
        expect(req.url.toString(), '$_baseUrl/auth/social/exchange');
        expect(
          req.headers['content-type'],
          contains('application/x-www-form-urlencoded'),
        );
        expect(req.bodyFields['code'], 'HANDOFF123');
        expect(req.bodyFields['redirect_uri'], _redirectUri);
        // The code must NOT re-enter a request line — the spec reads it with
        // r.PostFormValue, so a query-string code would silently fail.
        expect(req.url.query, isEmpty);
      },
    );

    test(
      'tokens come from the RESPONSE BODY and land on the session (item 7)',
      () async {
        final rec = _Recorder();
        final svc = _service(
          rec.okClient(access: 'BODY_ACCESS', refresh: 'BODY_REFRESH'),
        );

        final session = await svc.completeCallback(
          callbackUrl: '$_redirectUri?code=HANDOFF123&state=STATE456',
          redirectUri: _redirectUri,
          expectedState: 'STATE456',
        );

        expect(session.accessToken, 'BODY_ACCESS');
        expect(session.refreshToken, 'BODY_REFRESH');
        // Consumer social login is user-scoped: no company, no role.
        expect(session.companyId, '');
        expect(session.role, '');
        expect(session.user.id, '');
      },
    );

    test('tokens in the callback URL are NEVER used, even when the exchange '
        'returns different values (item 5, end to end)', () async {
      final rec = _Recorder();
      final svc = _service(
        rec.okClient(access: 'BODY_ACCESS', refresh: 'BODY_REFRESH'),
      );

      final session = await svc.completeCallback(
        callbackUrl:
            '$_redirectUri?code=HANDOFF123&state=STATE456'
            '&access_token=URL_ACCESS&refresh_token=URL_REFRESH',
        redirectUri: _redirectUri,
        expectedState: 'STATE456',
      );

      expect(session.accessToken, 'BODY_ACCESS');
      expect(session.refreshToken, 'BODY_REFRESH');
      expect(session.accessToken, isNot('URL_ACCESS'));
      expect(session.refreshToken, isNot('URL_REFRESH'));
    });

    test(
      'a trailing slash on baseUrl does not produce a double slash',
      () async {
        final rec = _Recorder();
        final svc = SocialAuthService(
          repository: null,
          baseUrl: '$_baseUrl/',
          callbackScheme: _scheme,
          httpClient: rec.okClient(),
        );

        await svc.completeCallback(
          callbackUrl: '$_redirectUri?code=C&state=S',
          redirectUri: _redirectUri,
          expectedState: 'S',
        );

        expect(
          rec.requests.single.url.toString(),
          '$_baseUrl/auth/social/exchange',
        );
      },
    );
  });

  group('state verification (item 8 — CSRF)', () {
    test('a state MISMATCH aborts before any network call', () async {
      final rec = _Recorder();
      final svc = _service(rec.okClient());

      await expectLater(
        svc.completeCallback(
          callbackUrl: '$_redirectUri?code=HANDOFF123&state=ATTACKER_STATE',
          redirectUri: _redirectUri,
          expectedState: 'EXPECTED_STATE',
        ),
        throwsA(isA<AuthError>()),
      );

      // The assertion that matters: no request was MADE, not merely that an
      // error came back.
      expect(rec.requests, isEmpty);
    });

    test(
      'a MISSING state on the callback aborts before any network call',
      () async {
        final rec = _Recorder();
        final svc = _service(rec.okClient());

        await expectLater(
          svc.completeCallback(
            callbackUrl: '$_redirectUri?code=HANDOFF123',
            redirectUri: _redirectUri,
            expectedState: 'EXPECTED_STATE',
          ),
          throwsA(isA<AuthError>()),
        );
        expect(rec.requests, isEmpty);
      },
    );

    test('a matching state proceeds to the exchange', () async {
      final rec = _Recorder();
      final svc = _service(rec.okClient());

      await svc.completeCallback(
        callbackUrl: '$_redirectUri?code=HANDOFF123&state=SAME',
        redirectUri: _redirectUri,
        expectedState: 'SAME',
      );
      expect(rec.requests, hasLength(1));
    });
  });

  group('failure modes are distinguishable (item 9)', () {
    test(
      'a 400 from the exchange is an AuthError, NOT a NetworkError',
      () async {
        final rec = _Recorder();
        final svc = _service(
          rec.client((_) async => http.Response('invalid request', 400)),
        );

        await expectLater(
          svc.completeCallback(
            callbackUrl: '$_redirectUri?code=EXPIRED&state=S',
            redirectUri: _redirectUri,
            expectedState: 'S',
          ),
          throwsA(allOf(isA<AuthError>(), isNot(isA<NetworkError>()))),
        );
      },
    );

    test('a 405 (GET-shaped call) is an AuthError naming the status', () async {
      final rec = _Recorder();
      final svc = _service(
        rec.client((_) async => http.Response('Method Not Allowed', 405)),
      );

      await expectLater(
        svc.completeCallback(
          callbackUrl: '$_redirectUri?code=C&state=S',
          redirectUri: _redirectUri,
          expectedState: 'S',
        ),
        throwsA(isA<AuthError>()),
      );
    });

    // MUTATION-DRIVEN (M4). The two tests above were GREEN FOR THE WRONG
    // REASON: a 400 carries the body `invalid request`, which is not JSON, so
    // deleting the status check entirely still produced an AuthError — from
    // jsonDecode, not from the guard. Deleting `if (response.statusCode != 200)`
    // SURVIVED the whole suite.
    //
    // A non-200 whose body IS a well-formed token pair isolates the status
    // check: without it the client would accept tokens from a REFUSED exchange.
    test('a non-200 carrying a VALID token-pair JSON body is still refused — '
        'the status check is load-bearing, not the JSON parser', () async {
      final rec = _Recorder();
      final svc = _service(
        rec.client(
          (_) async => http.Response(
            jsonEncode({
              'access_token': 'SHOULD_NEVER_BE_USED',
              'refresh_token': 'SHOULD_NEVER_BE_USED_EITHER',
            }),
            400,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );

      await expectLater(
        svc.completeCallback(
          callbackUrl: '$_redirectUri?code=REPLAYED&state=S',
          redirectUri: _redirectUri,
          expectedState: 'S',
        ),
        throwsA(isA<AuthError>()),
      );
    });

    test(
      'a 500 carrying a valid token-pair JSON body is refused too',
      () async {
        final rec = _Recorder();
        final svc = _service(
          rec.client(
            (_) async => http.Response(
              jsonEncode({'access_token': 'A', 'refresh_token': 'B'}),
              500,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );

        await expectLater(
          svc.completeCallback(
            callbackUrl: '$_redirectUri?code=C&state=S',
            redirectUri: _redirectUri,
            expectedState: 'S',
          ),
          throwsA(isA<AuthError>()),
        );
      },
    );

    test('a transport failure is a NetworkError, NOT an AuthError', () async {
      final rec = _Recorder();
      final svc = _service(
        rec.client((_) async => throw http.ClientException('connection reset')),
      );

      await expectLater(
        svc.completeCallback(
          callbackUrl: '$_redirectUri?code=C&state=S',
          redirectUri: _redirectUri,
          expectedState: 'S',
        ),
        throwsA(allOf(isA<NetworkError>(), isNot(isA<AuthError>()))),
      );
    });

    test('a 200 with a malformed/empty body is an AuthError, not a session '
        'with empty tokens', () async {
      final rec = _Recorder();
      final svc = _service(
        rec.client(
          (_) async => http.Response(
            jsonEncode({'access_token': '', 'refresh_token': ''}),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );

      await expectLater(
        svc.completeCallback(
          callbackUrl: '$_redirectUri?code=C&state=S',
          redirectUri: _redirectUri,
          expectedState: 'S',
        ),
        throwsA(isA<AuthError>()),
      );
    });

    test(
      'a 200 with non-JSON body is an AuthError rather than a crash',
      () async {
        final rec = _Recorder();
        final svc = _service(
          rec.client((_) async => http.Response('<html>oops</html>', 200)),
        );

        await expectLater(
          svc.completeCallback(
            callbackUrl: '$_redirectUri?code=C&state=S',
            redirectUri: _redirectUri,
            expectedState: 'S',
          ),
          throwsA(isA<AuthError>()),
        );
      },
    );
  });

  // A NAME-based gate is insufficient: eden-platform-go proved a token
  // can ship under a benign parameter name while a `grep access_token=` gate
  // passes. These assert on the token VALUE, wherever in the URL it hides.
  group('no token VALUE from the callback URL ever reaches the session', () {
    const smuggled = 'SMUGGLED_TOKEN_VALUE_9f3a';

    final hidingPlaces = <String, String>{
      'the canonical parameter name':
          '$_redirectUri?code=C&state=S&access_token=$smuggled',
      'a benign parameter name (the the spec D6-M2 smuggling case)':
          '$_redirectUri?t=$smuggled&code=C&state=S',
      'an innocuous-looking parameter':
          '$_redirectUri?profile=$smuggled&code=C&state=S',
      'the fragment': '$_redirectUri?code=C&state=S#access_token=$smuggled',
      'the path':
          'com.example.testapp://auth/social/callback/$smuggled?code=C&state=S',
      'userinfo': 'https://$smuggled@app.example.test/auth.html?code=C&state=S',
      'the state value itself': '$_redirectUri?code=C&state=S',
    };

    hidingPlaces.forEach((where, callbackUrl) {
      test('a token hidden in $where is never used', () async {
        final rec = _Recorder();
        final svc = _service(
          rec.okClient(access: 'BODY_ACCESS', refresh: 'BODY_REFRESH'),
        );

        final session = await svc.completeCallback(
          callbackUrl: callbackUrl,
          redirectUri: _redirectUri,
          expectedState: 'S',
        );

        expect(session.accessToken, isNot(contains(smuggled)));
        expect(session.refreshToken, isNot(contains(smuggled)));
        expect(session.accessToken, 'BODY_ACCESS');
        expect(session.refreshToken, 'BODY_REFRESH');
      });
    });

    test(
      'the exchange REQUEST never carries a URL-borne token either',
      () async {
        final rec = _Recorder();
        final svc = _service(rec.okClient());

        await svc.completeCallback(
          callbackUrl: '$_redirectUri?code=C&state=S&access_token=$smuggled',
          redirectUri: _redirectUri,
          expectedState: 'S',
        );

        final req = rec.requests.single;
        expect(req.url.toString(), isNot(contains(smuggled)));
        expect(req.body, isNot(contains(smuggled)));
      },
    );
  });

  group('fragment-shaped redirect (hash-routed SPA — the spec composes the query '
      'INSIDE the fragment)', () {
    test('code + state are read out of the fragment query', () async {
      final rec = _Recorder();
      final svc = _service(rec.okClient());

      final session = await svc.completeCallback(
        callbackUrl:
            'https://app.example.test/#/auth/complete?code=FRAGCODE&state=FRAGSTATE',
        redirectUri: 'https://app.example.test/#/auth/complete',
        expectedState: 'FRAGSTATE',
      );

      expect(rec.requests.single.bodyFields['code'], 'FRAGCODE');
      expect(session.accessToken, 'acc-from-body');
    });

    test('a fragment-shaped callback with a mismatched state still aborts '
        'before any network call', () async {
      final rec = _Recorder();
      final svc = _service(rec.okClient());

      await expectLater(
        svc.completeCallback(
          callbackUrl:
              'https://app.example.test/#/auth/complete?code=FRAGCODE&state=WRONG',
          redirectUri: 'https://app.example.test/#/auth/complete',
          expectedState: 'FRAGSTATE',
        ),
        throwsA(isA<AuthError>()),
      );
      expect(rec.requests, isEmpty);
    });
  });

  group('stateFromAuthUrl', () {
    test('extracts the state the server embedded in the authorization URL', () {
      final state = SocialAuthService.stateFromAuthUrl(
        'https://accounts.google.com/o/oauth2/v2/auth'
        '?client_id=x&state=SERVER_STATE_JWT&redirect_uri=y',
      );
      expect(state, 'SERVER_STATE_JWT');
    });

    test('returns null when the authorization URL carries no state', () {
      final state = SocialAuthService.stateFromAuthUrl(
        'https://accounts.google.com/o/oauth2/v2/auth?client_id=x',
      );
      expect(state, isNull);
    });
  });
}
