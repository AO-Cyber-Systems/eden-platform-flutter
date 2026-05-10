import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Dio HTTP adapter that hands back a scripted sequence of statuses and
/// counts how many requests made it to the wire.
class _CountingAdapter implements HttpClientAdapter {
  _CountingAdapter(this.statuses);

  /// Sequence of statuses to return; after the list is exhausted the last
  /// entry is reused. Use a single-element list for "always respond with X".
  final List<int> statuses;
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final index =
        requestCount < statuses.length ? requestCount : statuses.length - 1;
    final status = statuses[index];
    requestCount += 1;
    final body = utf8.encode(jsonEncode({'status': status}));
    return ResponseBody.fromBytes(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _buildDio(
  _CountingAdapter adapter, {
  int maxRetries = 2,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
    ..httpClientAdapter = adapter;
  dio.interceptors.add(RetryInterceptor(
    dio: dio,
    maxRetries: maxRetries,
    initialDelay: const Duration(milliseconds: 1),
  ));
  return dio;
}

void main() {
  group('RetryInterceptor', () {
    test('does NOT retry a 404 — exactly 1 request attempt', () async {
      final adapter = _CountingAdapter([404]);
      final dio = _buildDio(adapter);

      await expectLater(
        dio.get<dynamic>('/api/v1/conversations/deleted/messages'),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'statusCode', 404)),
      );

      expect(adapter.requestCount, 1,
          reason: '4xx should be terminal — no retries');
    });

    test('does NOT retry other 4xx responses (400, 403, 422)', () async {
      for (final status in [400, 403, 422]) {
        final adapter = _CountingAdapter([status]);
        final dio = _buildDio(adapter);

        await expectLater(
          dio.get<dynamic>('/any'),
          throwsA(isA<DioException>()),
        );
        expect(adapter.requestCount, 1,
            reason: 'status=$status should not be retried');
      }
    });

    test('retries a 500 up to 2 times -> max 3 total attempts', () async {
      final adapter = _CountingAdapter([500]);
      final dio = _buildDio(adapter);

      await expectLater(
        dio.get<dynamic>('/flaky'),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'statusCode', 500)),
      );

      expect(adapter.requestCount, 3,
          reason: '1 initial + 2 retries on 5xx');
    });

    test('succeeds when a retried 503 recovers on attempt 2', () async {
      final adapter = _CountingAdapter([503, 200]);
      final dio = _buildDio(adapter);

      final response = await dio.get<dynamic>('/sometimes');
      expect(response.statusCode, 200);
      expect(adapter.requestCount, 2,
          reason: '1 failure + 1 successful retry');
    });

    test('does NOT retry non-idempotent POST on 5xx', () async {
      final adapter = _CountingAdapter([500]);
      final dio = _buildDio(adapter);

      await expectLater(
        dio.post<dynamic>('/mutate', data: {'x': 1}),
        throwsA(isA<DioException>()),
      );

      expect(adapter.requestCount, 1,
          reason: 'POST on 5xx must not auto-retry (possible double-submit)');
    });

    test('respects custom maxRetries = 0 (no retries at all)', () async {
      final adapter = _CountingAdapter([500]);
      final dio = _buildDio(adapter, maxRetries: 0);

      await expectLater(
        dio.get<dynamic>('/disabled'),
        throwsA(isA<DioException>()),
      );

      expect(adapter.requestCount, 1);
    });
  });
}
