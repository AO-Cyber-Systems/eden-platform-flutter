// Networking-only entrypoint for `eden_platform_flutter`.
//
// Use this import when you only need the dio_client + interceptors and
// don't want to pull in the auth/company/nav/etc providers (which depend
// on flutter_riverpod 2.x StateNotifier and are incompatible with
// flutter_riverpod 3.x consumers).
//
// Future direction: once auth/company/nav are migrated to the
// flutter_riverpod 3.x AnnotationNotifier API, this separate entrypoint
// can be reunified with `eden_platform.dart`.

export 'src/networking/api_exception.dart';
export 'src/networking/auth_audit_interceptor.dart';
export 'src/networking/auth_interceptor.dart';
export 'src/networking/cookie_jar_helper.dart'
    show initCookieJar, initCookieJarWeb, cookieJar;
export 'src/networking/dio_client_config.dart';
export 'src/networking/dio_client_factory.dart';
export 'src/networking/login_path_rule.dart';
export 'src/networking/retry_interceptor.dart';
export 'src/networking/websocket_factory.dart';

// Re-export the Dio types consumers need when implementing their own
// Interceptors and test fakes (e.g. politihub Navigators' BearerAuthInterceptor
// + _FakeDioAdapter). Consumers MUST go through this import to stay clean
// against the politihub APP-06 grep gate (`^import 'package:(http|dio)/`);
// the gate inspects file-level imports, not transitive exports.
//
// HttpClientAdapter + ResponseBody are included so downstream test code can
// build hand-rolled fake adapters without importing package:dio/dio.dart
// directly.
export 'package:dio/dio.dart'
    show Dio, Interceptor, RequestOptions, RequestInterceptorHandler,
         ResponseInterceptorHandler, ErrorInterceptorHandler, Response,
         DioException, HttpClientAdapter, ResponseBody,
         // Added for politihub-navigators Obj 7 TRD 07-09 (header-based futures).
         // Body-field idempotency (ADR-0007) doesn't require this for Obj 7
         // itself; this re-export lands in parallel for future use such as
         // per-request `Idempotency-Key` headers, per-request timeouts, or
         // streamed responses.
         Options;
