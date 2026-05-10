import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_dio/sentry_dio.dart';

import 'auth_audit_interceptor.dart';
import 'auth_interceptor.dart';
import 'dio_client_config.dart';
import 'retry_interceptor.dart';

/// Factory for the Eden-standard [Dio] client.
///
/// Wires the canonical interceptor chain in the canonical order. Each
/// consuming app passes its own [DioClientConfig]; the factory does NOT
/// hold onto a Riverpod ref or any framework-specific state — apps wrap
/// the result in their own provider as appropriate.
///
/// ## Interceptor order
///
/// Order matters because Dio runs request interceptors top-to-bottom and
/// response/error interceptors bottom-to-top. The default chain is:
///
/// 1. [AuthAuditInterceptor] — first so it sees raw responses before any
///    other interceptor mutates them. Logs auth-relevant signals (401s,
///    CORS headers, login response shape) without ever logging cookie
///    values or bodies.
/// 2. [CookieManager] (native only) — persists session cookies. Skipped on
///    web because the browser owns the cookie jar via CORS.
/// 3. [RetryInterceptor] — registered before [AuthInterceptor] so transient
///    5xx retries complete before auth logic sees a final failure. Only
///    retries idempotent methods on 5xx + network errors (max 2 retries,
///    exp backoff from 500 ms). 4xx is terminal — never retried.
/// 4. [AuthInterceptor] — converts 401 from a non-login endpoint into the
///    [DioClientConfig.onUnauthorized] callback so the app can flip its
///    auth state to unauthenticated.
/// 5. Debug-only [LogInterceptor] (when [DioClientConfig.enableDebugLogging]
///    is true and `kDebugMode` is true) — logs request/response headers +
///    request body (NOT response body — too expensive for list endpoints).
///    Cookies are redacted in the output.
/// 6. [Dio.addSentry] (when [DioClientConfig.enableSentry] is true) —
///    breadcrumbs + HTTP spans for every request. No-ops if Sentry isn't
///    initialized.
class DioClientFactory {
  const DioClientFactory._();

  /// Build a [Dio] instance from [config].
  static Dio create(DioClientConfig config) {
    final dio = Dio(
      BaseOptions(
        baseUrl: config.baseUrl,
        connectTimeout: config.connectTimeout,
        receiveTimeout: config.receiveTimeout,
        headers: const {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        // On web, let the browser send cookies automatically via CORS.
        extra: kIsWeb ? const {'withCredentials': true} : null,
      ),
    );

    // 1. AuthAuditInterceptor (first — sees raw responses).
    dio.interceptors.add(AuthAuditInterceptor(
      loginPath: config.auditLoginPath,
      logTag: config.auditLogTag,
    ));

    // 2. Cookie manager (native only).
    if (!kIsWeb && config.cookieJar != null) {
      dio.interceptors.add(CookieManager(config.cookieJar!));
    }

    // 3. RetryInterceptor — before AuthInterceptor so 5xx retries finish
    // before the auth flow sees a final failure.
    dio.interceptors.add(RetryInterceptor(
      dio: dio,
      maxRetries: config.retryPolicy.maxRetries,
      initialDelay: config.retryPolicy.initialDelay,
    ));

    // 4. AuthInterceptor — 401 from non-login endpoints triggers callback.
    dio.interceptors.add(AuthInterceptor(
      onUnauthorized: config.onUnauthorized,
      loginPaths: config.loginPaths,
    ));

    // 5. Debug log (kDebugMode only).
    if (config.enableDebugLogging && kDebugMode) {
      dio.interceptors.add(
        LogInterceptor(
          requestHeader: true,
          responseHeader: true,
          requestBody: true,
          // responseBody=false: even in debug, printing every full response
          // body adds hundreds of ms per request for list endpoints. Status +
          // headers are enough to spot most issues; flip this locally when
          // debugging a specific payload.
          responseBody: false,
          logPrint: (object) {
            final line = object.toString();
            if (line.contains('cookie:') || line.contains('set-cookie:')) {
              debugPrint('[DIO] [REDACTED COOKIE]');
            } else {
              debugPrint('[DIO] $line');
            }
          },
        ),
      );
    }

    // 6. Sentry Dio integration. No-ops if Sentry isn't initialized.
    if (config.enableSentry) {
      dio.addSentry();
    }

    return dio;
  }
}
