import 'package:dio/dio.dart';
import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DioClientFactory.create', () {
    test('builds a Dio with the configured base URL and timeouts', () {
      final dio = DioClientFactory.create(
        const DioClientConfig(
          baseUrl: 'https://api.example.com',
          connectTimeout: Duration(seconds: 5),
          receiveTimeout: Duration(seconds: 10),
          enableSentry: false,
          enableDebugLogging: false,
        ),
      );

      expect(dio.options.baseUrl, 'https://api.example.com');
      expect(dio.options.connectTimeout, const Duration(seconds: 5));
      expect(dio.options.receiveTimeout, const Duration(seconds: 10));
    });

    test('attaches AuthAuditInterceptor as the first user interceptor', () {
      final dio = DioClientFactory.create(
        const DioClientConfig(
          baseUrl: 'https://api.example.com',
          enableSentry: false,
          enableDebugLogging: false,
        ),
      );

      // Dio inserts its own `ImplyContentTypeInterceptor` at index 0 — that's
      // a framework concern, not ours. The first USER-installed interceptor
      // must be the audit interceptor so it sees raw responses before any
      // other user interceptor mutates them.
      final auditIndex =
          dio.interceptors.indexWhere((i) => i is AuthAuditInterceptor);
      final retryIndex =
          dio.interceptors.indexWhere((i) => i is RetryInterceptor);
      final authIndex =
          dio.interceptors.indexWhere((i) => i is AuthInterceptor);
      expect(auditIndex, greaterThanOrEqualTo(0));
      expect(auditIndex, lessThan(retryIndex),
          reason: 'audit must run before retry');
      expect(auditIndex, lessThan(authIndex),
          reason: 'audit must run before auth');
    });

    test('attaches RetryInterceptor before AuthInterceptor', () {
      final dio = DioClientFactory.create(
        const DioClientConfig(
          baseUrl: 'https://api.example.com',
          enableSentry: false,
          enableDebugLogging: false,
        ),
      );

      final retryIndex =
          dio.interceptors.indexWhere((i) => i is RetryInterceptor);
      final authIndex =
          dio.interceptors.indexWhere((i) => i is AuthInterceptor);
      expect(retryIndex, greaterThanOrEqualTo(0));
      expect(authIndex, greaterThanOrEqualTo(0));
      expect(retryIndex, lessThan(authIndex),
          reason:
              'retry must run before auth so 5xx retries finish before auth flow sees a final failure');
    });

    test('passes loginPaths through to AuthInterceptor', () {
      const rules = [
        LoginPathRule.exact('POST', '/api/v1/session'),
        LoginPathRule.contains('GET', '/insights'),
      ];

      final dio = DioClientFactory.create(
        const DioClientConfig(
          baseUrl: 'https://api.example.com',
          loginPaths: rules,
          enableSentry: false,
          enableDebugLogging: false,
        ),
      );

      final auth = dio.interceptors.firstWhere((i) => i is AuthInterceptor)
          as AuthInterceptor;
      expect(auth.loginPaths, hasLength(2));
      expect(auth.isLoginPath('/api/v1/session', 'POST'), isTrue);
      expect(auth.isLoginPath('/api/v1/x/y/insights', 'GET'), isTrue);
      expect(auth.isLoginPath('/api/v1/profile', 'GET'), isFalse);
    });

    test('passes onUnauthorized callback through to AuthInterceptor', () async {
      final calls = <String>[];

      final dio = DioClientFactory.create(
        DioClientConfig(
          baseUrl: 'https://api.example.com',
          onUnauthorized: calls.add,
          enableSentry: false,
          enableDebugLogging: false,
        ),
      );

      final auth = dio.interceptors.firstWhere((i) => i is AuthInterceptor)
          as AuthInterceptor;
      final ro = RequestOptions(path: '/api/v1/profile');
      await auth.onError(
        DioException(
          requestOptions: ro,
          response: Response(requestOptions: ro, statusCode: 401),
        ),
        _NoopErrorHandler(),
      );
      expect(calls, ['/api/v1/profile']);
    });

    test('skips CookieManager on web (kIsWeb branch)', () {
      // Sanity check: in test env (native), if we DON'T pass a cookieJar, no
      // cookie manager should be installed (factory only registers if
      // cookieJar != null && !kIsWeb). On web, it's also skipped.
      final dio = DioClientFactory.create(
        const DioClientConfig(
          baseUrl: 'https://api.example.com',
          cookieJar: null,
          enableSentry: false,
          enableDebugLogging: false,
        ),
      );

      // CookieManager isn't exported by eden_platform.dart; check by name.
      final hasCookieManager = dio.interceptors.any(
        (i) => i.runtimeType.toString() == 'CookieManager',
      );
      expect(hasCookieManager, isFalse);
    });

    test('respects custom RetryPolicy', () {
      final dio = DioClientFactory.create(
        const DioClientConfig(
          baseUrl: 'https://api.example.com',
          retryPolicy: RetryPolicy(
            maxRetries: 5,
            initialDelay: Duration(seconds: 2),
          ),
          enableSentry: false,
          enableDebugLogging: false,
        ),
      );

      final retry = dio.interceptors.firstWhere((i) => i is RetryInterceptor)
          as RetryInterceptor;
      expect(retry.maxRetries, 5);
      expect(retry.initialDelay, const Duration(seconds: 2));
    });

    test('debug log gating: not present when enableDebugLogging=false', () {
      final dio = DioClientFactory.create(
        const DioClientConfig(
          baseUrl: 'https://api.example.com',
          enableSentry: false,
          enableDebugLogging: false,
        ),
      );

      final hasLog = dio.interceptors.any((i) => i is LogInterceptor);
      expect(hasLog, isFalse);
    });

    test('debug log gating: present in kDebugMode when enabled', () {
      // kDebugMode is true in `flutter test` runs.
      final dio = DioClientFactory.create(
        const DioClientConfig(
          baseUrl: 'https://api.example.com',
          enableSentry: false,
          enableDebugLogging: true,
        ),
      );

      final hasLog = dio.interceptors.any((i) => i is LogInterceptor);
      expect(hasLog, kDebugMode,
          reason: 'LogInterceptor present iff kDebugMode && enableDebugLogging');
    });
  });
}

class _NoopErrorHandler extends ErrorInterceptorHandler {
  @override
  void next(DioException err) {}
}
