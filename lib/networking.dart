// Networking-only entrypoint for `eden_platform_flutter`.
//
// HISTORY: this entrypoint existed because the auth/company/nav providers were
// built on flutter_riverpod 2.x StateNotifier and were therefore unusable from
// a riverpod 3.x consumer. AOID objective 50 (50-CONTEXT.md D2) migrated all
// five notifiers to the 3.x Notifier API, so that incompatibility NO LONGER
// EXISTS — see doc/riverpod-3-migration.md. This file's old header named that
// migration as the precondition for reunification; TRD 50-24 is where it came
// true.
//
// It is KEPT, not deleted, for two reasons:
//   1. Four consumer packages import only this entrypoint and nothing else —
//      aodex/flutter and aofamily/{ai,connect,browser}. Deleting it turns a
//      zero-change consumer wave into four broken repositories.
//   2. It re-exports the dio symbols that politihub's APP-06 grep gate requires
//      consumers to obtain HERE rather than from package:dio directly (that
//      gate inspects file-level imports, not transitive exports). See the
//      export block below — do not remove it, do not relocate it, and do not
//      let it become transitive by collapsing this file into a bare re-export.
//
// Reunification therefore means "the split is no longer FORCED, and this header
// no longer lies" — not "a file disappears". What changed is the rationale: the
// narrower surface is now a deliberate convenience for consumers that want only
// the transport, rather than a firewall around a version conflict.
//
// Prefer `eden_platform.dart` for new code: it is the full surface, and taking
// it no longer costs you a riverpod version conflict.
//
// NOTE for anyone diffing the two entrypoints: they are NOT nested in either
// direction. This file re-exports dio symbols `eden_platform.dart` does not,
// and `eden_platform.dart` exports connect_cookie_interceptor, sentry_init, the
// two provider base classes, the riverpod snapshot bridge and the whole AOID
// SDK, none of which are here. A "merge" that assumes nesting changes both.

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
// Connect transport helpers — upstreamed from eden-biz.
export 'src/networking/connect_bearer_interceptor.dart';
export 'src/networking/proactive_refresh.dart';

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
