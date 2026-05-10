import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Lightweight Dio interceptor that logs auth-relevant request/response
/// signals in release builds. Runs on every request but only prints when
/// something is worth investigating — 401/403 responses, missing CORS
/// headers, or Set-Cookie presence on login.
///
/// Security: never logs cookie values, tokens, request bodies, or
/// authorization headers. Only logs presence booleans, status codes,
/// and public CORS header values.
///
/// The default [loginPath] is `/api/v1/session` (the Rails Devise convention
/// shared by most Eden products). Override for products that diverge.
class AuthAuditInterceptor extends Interceptor {
  AuthAuditInterceptor({
    this.loginPath = '/api/v1/session',
    this.logTag = 'AuthAudit',
  });

  /// Path suffix that identifies the login + session-validate endpoint.
  /// Matched with `path.endsWith(loginPath)` so prefixes (`/api/v1/...`)
  /// don't matter.
  final String loginPath;

  /// Tag prepended to every log line. Useful when more than one app shares
  /// log output (`[AuthAudit-AODex]` vs `[AuthAudit-AOFamily]`).
  final String logTag;

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final status = response.statusCode ?? 0;
    final path = response.requestOptions.path;
    final method = response.requestOptions.method;

    // Log login responses to verify Set-Cookie and CORS headers.
    if (method == 'POST' && path.endsWith(loginPath)) {
      final headers = response.headers;
      debugPrint(
        '[$logTag] login response '
        'status=$status '
        'has_set_cookie=${headers.value("set-cookie") != null} '
        'has_ws_token=${response.data is Map && response.data["ws_token"] != null} '
        'acao=${headers.value("access-control-allow-origin") ?? ""} '
        'acac=${headers.value("access-control-allow-credentials") ?? ""}',
      );
    }

    // Log session validation responses.
    if (method == 'GET' && path.endsWith(loginPath)) {
      debugPrint(
        '[$logTag] session validate '
        'status=$status',
      );
    }

    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final status = err.response?.statusCode;
    final path = err.requestOptions.path;
    final method = err.requestOptions.method;

    if (status == 401 || status == 403) {
      final headers = err.response?.headers;
      debugPrint(
        '[$logTag] $status on $method $path '
        'acao=${headers?.value("access-control-allow-origin") ?? "missing"} '
        'acac=${headers?.value("access-control-allow-credentials") ?? "missing"} '
        'type=${err.type.name}',
      );
    } else if (err.type == DioExceptionType.connectionError ||
        err.type == DioExceptionType.unknown) {
      // CORS blocks surface as connection errors in the browser — the
      // response never reaches JavaScript.
      debugPrint(
        '[$logTag] connection error on $method $path '
        'type=${err.type.name} '
        'message=${_truncate(err.message ?? "", 120)}',
      );
    }

    handler.next(err);
  }

  static String _truncate(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}...';
  }
}
