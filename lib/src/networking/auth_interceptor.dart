import 'package:dio/dio.dart';

import 'login_path_rule.dart';

/// Callback invoked when a 401 is received from an authed endpoint.
///
/// Receives the request path so callers can react to the path that triggered
/// the unauthorized signal (e.g. for telemetry).
typedef OnUnauthorized = void Function(String requestPath);

/// Session-based auth interceptor for cookie-authed APIs.
///
/// Cookie management is handled by the cookie manager interceptor (e.g.
/// `dio_cookie_manager` on native, browser cookie jar on web). This
/// interceptor only handles:
/// - 401 detection from authed endpoints -> triggers [onUnauthorized]
/// - 401 from paths in [loginPaths] is NOT a session-expiry signal — those
///   endpoints carry meanings other than "session expired" (e.g. login POST
///   returns 401 for wrong password, 2FA verification returns 401 for wrong
///   code). These are surfaced as normal errors for the caller to handle.
///
/// Each consuming app passes its own [loginPaths] list. AODex passes the
/// Rails Devise login flow; AOFamily passes a different set; etc.
class AuthInterceptor extends QueuedInterceptor {
  AuthInterceptor({
    this.onUnauthorized,
    this.loginPaths = const [],
  });

  final OnUnauthorized? onUnauthorized;

  /// Rules describing paths whose 401 must NOT trigger [onUnauthorized].
  final List<LoginPathRule> loginPaths;

  /// Returns true if the given path+method is a "login path" — i.e. a 401
  /// there must NOT trigger the session-expiry callback.
  bool isLoginPath(String path, String? method) {
    for (final rule in loginPaths) {
      if (rule.matches(path, method)) return true;
    }
    return false;
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (err.response?.statusCode == 401) {
      final path = err.requestOptions.path;
      final method = err.requestOptions.method;
      if (!isLoginPath(path, method)) {
        onUnauthorized?.call(path);
      }
    }

    handler.next(err);
  }
}
