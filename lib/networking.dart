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
