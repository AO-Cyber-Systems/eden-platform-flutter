// What this file is for.
//
// `ConnectPlatformRepository._authPost` used to interpolate the HTTP status
// code and the raw response body into the `AuthError` message:
//
//     throw AuthError('Auth $method failed (HTTP ${resp.statusCode}): ${resp.body}');
//
// That message is rendered verbatim by `PlatformLoginScreen`'s error box. On
// 2026-09-24 a volunteer trying to sign in to politihub read
//
//     Auth Login failed (HTTP 401): {"error":"invalid email or password"}
//
// nine times in 62 minutes.
//
// THE ASSERTIONS HERE ARE ABOUT THE *ABSENCE* OF WIRE DETAIL, deliberately, and
// not about the new copy. `expect(err.message, "We couldn't sign you in...")`
// would pass just as happily against a future edit that re-appended the body;
// `isNot(contains('HTTP '))` would not. Keep it that way.
//
// The tests drive the REAL `ConnectPlatformRepository` against a REAL loopback
// HTTP server. `_authPost` calls the top-level `http.post`, which has no
// injection seam — the loopback server is what makes that a feature rather than
// an obstacle. No mocks, no fakes, no production seam added for testability.
//
// Every fixture below is hand-written.

import 'dart:convert';
import 'dart:io';

import 'package:eden_platform_flutter/src/api/platform_repository.dart';
import 'package:eden_platform_flutter/src/errors/platform_errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late String baseUrl;

  // Set per test, read by the handler below.
  late int responseStatus;
  late String responseBody;

  setUp(() async {
    // Port 0 asks the OS for an ephemeral port. NEVER a fixed port.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://localhost:${server.port}';

    responseStatus = 200;
    responseBody = '{}';

    server.listen((HttpRequest req) async {
      req.response.statusCode = responseStatus;
      req.response.headers.contentType = ContentType.json;
      req.response.write(responseBody);
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  ConnectPlatformRepository repo() =>
      ConnectPlatformRepository(baseUrl: baseUrl);

  /// Calls [body] and returns the [AuthError] it threw.
  Future<AuthError> captureAuthError(Future<void> Function() body) async {
    try {
      await body();
    } on AuthError catch (e) {
      return e;
    }
    fail('expected an AuthError, but the call returned normally');
  }

  group('_authPost non-200 — the wire never reaches the person', () {
    // Case 1
    test('a 401 from Login throws AuthError carrying no status code and no body',
        () async {
      responseStatus = 401;
      responseBody = '{"error":"invalid email or password"}';

      final err = await captureAuthError(
        () => repo().login('judy@example.test', 'hunter2'),
      );

      expect(err.message, isNot(contains('HTTP ')));
      expect(err.message, isNot(contains('{')));
      expect(err.message, isNotEmpty);
    });

    // Case 2
    test('a 401 from RefreshToken is equally clean — the fix is not login-only',
        () async {
      responseStatus = 401;
      responseBody = '{"error":"refresh token expired"}';

      final err = await captureAuthError(
        () => repo().refreshToken('stale-refresh-token'),
      );

      expect(err.message, isNot(contains('HTTP ')));
      expect(err.message, isNot(contains('{')));
      expect(err.message, isNotEmpty);
    });

    // Case 3
    test('a 409 from SignUp is equally clean', () async {
      responseStatus = 409;
      responseBody = '{"error":"email already registered"}';

      final err = await captureAuthError(
        () => repo().signUp('judy@example.test', 'hunter2', 'Judy'),
      );

      expect(err.message, isNot(contains('HTTP ')));
      expect(err.message, isNot(contains('{')));
      expect(err.message, isNotEmpty);
    });

    // Case 6 — the branch is status-agnostic, not a 401 special case.
    test('a 500 from Login is also clean', () async {
      responseStatus = 500;
      responseBody = '{"error":"internal"}';

      final err = await captureAuthError(
        () => repo().login('judy@example.test', 'hunter2'),
      );

      expect(err.message, isNot(contains('HTTP ')));
      expect(err.message, isNot(contains('{')));
      expect(err.message, isNot(contains('500')));
      expect(err.message, isNotEmpty);
    });

    // Case 4 — three situations, three sentences.
    test('the three methods produce DISTINCT messages', () async {
      responseStatus = 401;
      responseBody = '{"error":"nope"}';

      final login = await captureAuthError(
        () => repo().login('judy@example.test', 'hunter2'),
      );
      final signUp = await captureAuthError(
        () => repo().signUp('judy@example.test', 'hunter2', 'Judy'),
      );
      final refresh = await captureAuthError(
        () => repo().refreshToken('stale'),
      );

      expect(
        {login.message, signUp.message, refresh.message},
        hasLength(3),
        reason: 'the fix must not collapse three situations into one sentence',
      );
    });

    // Case 5 — the client stays no more specific about account existence than
    // the server's own deliberately generic 401 body. The server burns CPU on a
    // dummy verify to hide exactly this; copy must not give it back in English.
    test('no message is more specific about account existence than the server',
        () async {
      responseStatus = 401;
      responseBody = '{"error":"invalid email or password"}';

      final login = await captureAuthError(
        () => repo().login('judy@example.test', 'hunter2'),
      );
      final signUp = await captureAuthError(
        () => repo().signUp('judy@example.test', 'hunter2', 'Judy'),
      );
      final refresh = await captureAuthError(
        () => repo().refreshToken('stale'),
      );

      for (final message in [login.message, signUp.message, refresh.message]) {
        expect(message, isNot(contains('invalid email or password')));
        for (final banned in [
          'account',
          'exists',
          'found',
          'pending',
          'approval',
        ]) {
          expect(
            message.toLowerCase(),
            isNot(contains(banned)),
            reason: '"$banned" tells the reader something about the address '
                'that was typed — message was: $message',
          );
        }
      }
    });

    // Case 7 — the diagnostic is moved, not destroyed.
    test('the status code and raw body survive on AuthError.cause', () async {
      responseStatus = 401;
      responseBody = '{"error":"invalid email or password"}';

      final err = await captureAuthError(
        () => repo().login('judy@example.test', 'hunter2'),
      );

      expect(err.cause, isNotNull);
      final cause = err.cause.toString();
      expect(cause, contains('401'));
      expect(cause, contains('invalid email or password'));
      expect(cause, contains('Login'));
    });
  });

  group('_authPost 200 — the happy path is untouched', () {
    // Hand-written, from the field names _sessionFromJsonMap actually reads.
    // The access token is deliberately NOT a JWT: _extractClaims returns an
    // empty claim map for anything that is not three dot-separated parts, so
    // companyId / role stay null and the fixture needs no crypto.
    const userJson = {
      'id': 'user-0001',
      'email': 'judy@example.test',
      'displayName': 'Judy Petros',
      'avatarUrl': '',
      'isActive': true,
    };

    // Case 8
    test('a flat 200 body still returns a populated PlatformSession', () async {
      responseStatus = 200;
      responseBody = jsonEncode({
        'accessToken': 'flat-access-token',
        'refreshToken': 'flat-refresh-token',
        'user': userJson,
      });

      final session = await repo().login('judy@example.test', 'hunter2');

      expect(session.accessToken, 'flat-access-token');
      expect(session.refreshToken, 'flat-refresh-token');
      expect(session.user.id, 'user-0001');
      expect(session.user.email, 'judy@example.test');
      expect(session.user.displayName, 'Judy Petros');
    });

    // Case 9 — the dual-shape parse this TRD must not disturb.
    test('a nested 200 body still returns a populated PlatformSession',
        () async {
      responseStatus = 200;
      responseBody = jsonEncode({
        'auth': {
          'accessToken': 'nested-access-token',
          'refreshToken': 'nested-refresh-token',
          'user': userJson,
        },
      });

      final session = await repo().login('judy@example.test', 'hunter2');

      expect(session.accessToken, 'nested-access-token');
      expect(session.refreshToken, 'nested-refresh-token');
      expect(session.user.id, 'user-0001');
      expect(session.user.displayName, 'Judy Petros');
    });
  });

  group('_authPost transport failure — the outer catch is undisturbed', () {
    // Case 10 — proof the outer `catch` / NetworkError path still behaves. An
    // AuthError here would mean the non-200 branch had swallowed transport
    // errors too.
    test('a closed server yields NetworkError, not AuthError', () async {
      final deadUrl = baseUrl;
      await server.close(force: true);

      await expectLater(
        ConnectPlatformRepository(baseUrl: deadUrl)
            .login('judy@example.test', 'hunter2'),
        throwsA(isA<NetworkError>()),
      );

      // Re-bind so tearDown's close() has a live server to close.
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
  });
}
