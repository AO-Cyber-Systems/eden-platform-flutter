// Copyright 2026 AOCyber. All rights reserved.
//
// Tests for connectCookieInterceptor — native-mode cookie jar attach/parse
// + web-mode no-op behavior.
//
// Uses the connectrpc [FakeTransportBuilder] pattern with an injected
// jar (no global initialization) so each test is isolated.

library;

import 'package:connectrpc/connect.dart' as connect;
import 'package:connectrpc/test.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:eden_platform_flutter/src/networking/connect_cookie_interceptor.dart';
import 'package:flutter_test/flutter_test.dart';

final _fakeSpec = connect.Spec<String, String>(
  '/test.Service/FakeMethod',
  connect.StreamType.unary,
  () => '',
  () => '',
);

/// Send the fake RPC and capture both the headers the handler saw and the
/// transport's response. Optionally inject Set-Cookie values into the
/// response headers.
Future<({Map<String, String> requestHeaders, connect.UnaryResponse<String, String> response})>
    _invoke({
  required connect.Interceptor interceptor,
  Map<String, String> respondWithHeaders = const {},
}) async {
  final captured = <String, String>{};

  final transport = FakeTransportBuilder()
      .unary(_fakeSpec, (String req, FakeHandlerContext ctx) {
    for (final entry in ctx.requestHeaders.entries) {
      captured[entry.name] = entry.value;
    }
    for (final entry in respondWithHeaders.entries) {
      ctx.responseHeaders.add(entry.key, entry.value);
    }
    return '';
  }).build(interceptors: [interceptor]);

  final response =
      await transport.unary(_fakeSpec, '', const connect.CallOptions());
  return (
    requestHeaders: captured,
    response: response,
  );
}

void main() {
  group('connectCookieInterceptor — native mode (injected jar)', () {
    late CookieJar jar;
    setUp(() {
      jar = CookieJar();
    });

    test('attaches Cookie header from jar when jar has entries', () async {
      final uri = Uri.parse('test://test/test.Service/FakeMethod');
      await jar.saveFromResponse(uri, [
        Cookie('session', 'abc123'),
        Cookie('csrf', 'tok-xyz'),
      ]);

      final interceptor = connectCookieInterceptorForTest(jarReader: () => jar);

      final result = await _invoke(interceptor: interceptor);

      expect(result.requestHeaders['cookie'], isNotNull);
      expect(result.requestHeaders['cookie'], contains('session=abc123'));
      expect(result.requestHeaders['cookie'], contains('csrf=tok-xyz'));
    });

    test('attaches no Cookie header when jar is empty', () async {
      final interceptor = connectCookieInterceptorForTest(jarReader: () => jar);

      final result = await _invoke(interceptor: interceptor);

      expect(result.requestHeaders.containsKey('cookie'), isFalse);
    });

    test('parses Set-Cookie response header back into the jar', () async {
      final interceptor = connectCookieInterceptorForTest(jarReader: () => jar);

      await _invoke(
        interceptor: interceptor,
        respondWithHeaders: {
          'set-cookie': 'newsession=v9; Path=/; HttpOnly',
        },
      );

      final saved = await jar.loadForRequest(
        Uri.parse('test://test/test.Service/FakeMethod'),
      );
      final names = saved.map((c) => c.name).toList();
      expect(names, contains('newsession'));
      expect(
        saved.firstWhere((c) => c.name == 'newsession').value,
        'v9',
      );
    });

    test('round-trip: server sets cookie, subsequent request carries it',
        () async {
      final interceptor = connectCookieInterceptorForTest(jarReader: () => jar);

      // First call: no cookies on the way out, Set-Cookie on the way back.
      final first = await _invoke(
        interceptor: interceptor,
        respondWithHeaders: {'set-cookie': 'rt=phase1; Path=/'},
      );
      expect(first.requestHeaders.containsKey('cookie'), isFalse);

      // Second call: outbound request should now carry the cookie.
      final second = await _invoke(interceptor: interceptor);
      expect(second.requestHeaders['cookie'], contains('rt=phase1'));
    });

    test('uppercase Set-Cookie header is also persisted (HTTP/1.1 case)',
        () async {
      // The connectrpc Headers map normalizes to lowercase per its
      // contract, so this test exercises the case-insensitive match
      // implicitly via the contract — but we still want to confirm the
      // interceptor doesn't silently drop a Set-Cookie just because
      // someone hand-rolled the header name in mixed case.
      final interceptor = connectCookieInterceptorForTest(jarReader: () => jar);

      await _invoke(
        interceptor: interceptor,
        respondWithHeaders: {'Set-Cookie': 'mixed=yes; Path=/'},
      );

      final saved = await jar.loadForRequest(
        Uri.parse('test://test/test.Service/FakeMethod'),
      );
      expect(saved.map((c) => c.name), contains('mixed'));
    });
  });

  group('connectCookieInterceptor — web no-op mode', () {
    test('web-mode interceptor passes request through untouched', () async {
      final interceptor = connectCookieInterceptorWebForTest();

      final result = await _invoke(interceptor: interceptor);

      // No Cookie header should be added on web — browser owns the jar.
      expect(result.requestHeaders.containsKey('cookie'), isFalse);
    });

    test('web-mode interceptor does not crash on response with Set-Cookie',
        () async {
      // The browser would write Set-Cookie into its own jar; the Dart
      // interceptor must not double-handle it.
      final interceptor = connectCookieInterceptorWebForTest();

      final result = await _invoke(
        interceptor: interceptor,
        respondWithHeaders: {'set-cookie': 'foo=bar; Path=/'},
      );
      // We have no jar to assert against — the test passes as long as the
      // interceptor returns normally.
      expect(result.response, isNotNull);
    });
  });
}
