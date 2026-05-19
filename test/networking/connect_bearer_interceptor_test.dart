/// Tests for [connectBearerInterceptorForTest] and the underlying
/// ConnectBearerInterceptor bearer-header logic.
///
/// Uses the connectrpc [FakeTransportBuilder] pattern (same as eden-biz's
/// biz_transport_sentry_test.dart) with a minimal no-op handler so the
/// test doesn't need real generated proto types.
library;

import 'package:connectrpc/connect.dart' as connect;
import 'package:connectrpc/test.dart';
import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Minimal fake spec: a no-op unary service with String I/O
// ---------------------------------------------------------------------------

/// A [connect.Spec] for a fake unary call (no generated proto types needed).
final _fakeSpec = connect.Spec<String, String>(
  '/test.Service/FakeMethod',
  connect.StreamType.unary,
  () => '',
  () => '',
);

// ---------------------------------------------------------------------------
// Helper: invoke the fake RPC through [interceptor] and return the headers
// seen by the handler (i.e. after the interceptor has had a chance to mutate
// them).
// ---------------------------------------------------------------------------

Future<Map<String, String>> _headersSeenByHandler({
  required connect.Interceptor interceptor,
  String? initialAuthHeader,
}) async {
  final captured = <String, String>{};

  final transport = FakeTransportBuilder()
      .unary(_fakeSpec, (String req, FakeHandlerContext ctx) {
    for (final entry in ctx.requestHeaders.entries) {
      captured[entry.name] = entry.value;
    }
    return '';
  }).build(interceptors: [interceptor]);

  final options = connect.CallOptions(
    headers: initialAuthHeader != null
        ? (connect.Headers()..['authorization'] = initialAuthHeader)
        : null,
  );

  await transport.unary(_fakeSpec, '', options);
  return captured;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('connectBearerInterceptorForTest / ConnectBearerInterceptor', () {
    test('attaches Authorization: Bearer when token is non-null', () async {
      final interceptor =
          connectBearerInterceptorForTest(tokenReader: () => 'tok-abc');

      final headers = await _headersSeenByHandler(interceptor: interceptor);

      expect(
        headers['authorization'],
        'Bearer tok-abc',
        reason: 'non-null token must set the Authorization header',
      );
    });

    test('does not attach header when token is null', () async {
      final interceptor =
          connectBearerInterceptorForTest(tokenReader: () => null);

      final headers = await _headersSeenByHandler(interceptor: interceptor);

      expect(
        headers.containsKey('authorization'),
        isFalse,
        reason: 'null token → Authorization header must be absent',
      );
    });

    test('does not attach header when token is empty string', () async {
      final interceptor =
          connectBearerInterceptorForTest(tokenReader: () => '');

      final headers = await _headersSeenByHandler(interceptor: interceptor);

      expect(
        headers.containsKey('authorization'),
        isFalse,
        reason: 'empty string token must not set Authorization header',
      );
    });

    test('token value is passed through verbatim (no extra trimming)',
        () async {
      final interceptor =
          connectBearerInterceptorForTest(tokenReader: () => 'exact-token-99');

      final headers = await _headersSeenByHandler(interceptor: interceptor);

      expect(headers['authorization'], 'Bearer exact-token-99');
    });

    test('overwrites pre-existing authorization header with fresh token',
        () async {
      final interceptor =
          connectBearerInterceptorForTest(tokenReader: () => 'new-tok');

      final headers = await _headersSeenByHandler(
        interceptor: interceptor,
        initialAuthHeader: 'Bearer old-tok',
      );

      expect(
        headers['authorization'],
        'Bearer new-tok',
        reason: 'token from reader must win over any caller-supplied header',
      );
    });
  });
}
