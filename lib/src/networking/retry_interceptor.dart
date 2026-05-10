import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';

/// Retry interceptor for transient network + server errors.
///
/// Policy:
/// - 4xx responses are NEVER retried. Client errors are terminal — retrying
///   won't change the answer and only wastes backend + battery.
/// - 5xx responses and network-layer errors (timeouts, connection drops,
///   DNS failures) are retried up to [maxRetries] times.
/// - Backoff is exponential starting at [initialDelay]:
///   attempt 1 after 500 ms, attempt 2 after 1 s, attempt 3 after 2 s
///   (with the default 500 ms initialDelay).
/// - Non-idempotent methods (POST/PATCH/PUT/DELETE) are NOT retried by
///   default. Retry on 5xx is only safe for GET/HEAD/OPTIONS without extra
///   server-side idempotency guarantees.
///
/// Total attempts = 1 initial + up to [maxRetries] = max 3 requests with
/// the default `maxRetries = 2`.
class RetryInterceptor extends Interceptor {
  RetryInterceptor({
    required this.dio,
    this.maxRetries = 2,
    this.initialDelay = const Duration(milliseconds: 500),
  });

  final Dio dio;
  final int maxRetries;
  final Duration initialDelay;

  static const _retryCountKey = 'retry_interceptor.attempt';

  static const _idempotentMethods = {'GET', 'HEAD', 'OPTIONS'};

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;

    if (!_shouldRetry(err, options)) {
      handler.next(err);
      return;
    }

    final attempt = (options.extra[_retryCountKey] as int?) ?? 0;
    if (attempt >= maxRetries) {
      handler.next(err);
      return;
    }

    // Exponential backoff: 500ms, 1s, 2s, …
    final delay = initialDelay * math.pow(2, attempt).toInt();
    await Future<void>.delayed(delay);

    options.extra[_retryCountKey] = attempt + 1;

    try {
      final response = await dio.fetch<dynamic>(options);
      handler.resolve(response);
    } on DioException catch (retryErr) {
      handler.next(retryErr);
    }
  }

  bool _shouldRetry(DioException err, RequestOptions options) {
    // Only retry idempotent methods. POST/PATCH/PUT/DELETE retries could
    // double-submit on a transient 5xx — caller opts in per-request if
    // safe.
    final method = options.method.toUpperCase();
    if (!_idempotentMethods.contains(method)) {
      return false;
    }

    // Network-layer failures (no response) are always retryable.
    if (err.response == null) {
      switch (err.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionError:
          return true;
        case DioExceptionType.cancel:
        case DioExceptionType.badCertificate:
        case DioExceptionType.badResponse:
        case DioExceptionType.unknown:
          return false;
      }
    }

    final status = err.response?.statusCode ?? 0;
    // 4xx is terminal — never retry. 5xx is retryable.
    return status >= 500 && status < 600;
  }
}
