import 'package:cookie_jar/cookie_jar.dart';

import 'auth_interceptor.dart';
import 'login_path_rule.dart';

/// Retry policy passed to [DioClientFactory.create].
class RetryPolicy {
  const RetryPolicy({
    this.maxRetries = 2,
    this.initialDelay = const Duration(milliseconds: 500),
  });

  /// Maximum number of retry attempts after the initial request.
  /// Total attempts = 1 + maxRetries.
  final int maxRetries;

  /// Initial backoff delay before the first retry.
  /// Each subsequent retry doubles the delay.
  final Duration initialDelay;

  /// Default retry policy: max 2 retries, 500 ms initial delay
  /// (-> retries at 500 ms, 1 s).
  static const RetryPolicy defaultPolicy = RetryPolicy();
}

/// Configuration for [DioClientFactory.create].
///
/// Each Eden product builds its own Dio by passing this config; AODex,
/// AOFamily, AOSentry-admin, etc all share the same factory but supply
/// their own base URL, login-path rules, auth callback, and audit log path.
class DioClientConfig {
  const DioClientConfig({
    required this.baseUrl,
    this.connectTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 30),
    this.cookieJar,
    this.onUnauthorized,
    this.loginPaths = const [],
    this.retryPolicy = RetryPolicy.defaultPolicy,
    this.auditLoginPath = '/api/v1/session',
    this.auditLogTag = 'AuthAudit',
    this.enableSentry = true,
    this.enableDebugLogging = true,
  });

  /// Root URL for the API (e.g. `https://api.example.com`).
  /// Includes scheme + host; path prefix (e.g. `/api/v1`) belongs in the
  /// per-request path, not here.
  final String baseUrl;

  /// Maximum time to wait for the connection to be established.
  final Duration connectTimeout;

  /// Maximum time to wait between bytes during a response.
  final Duration receiveTimeout;

  /// Cookie jar used by the cookie-manager interceptor on native.
  /// Pass `null` on web — the browser handles cookies via CORS.
  final CookieJar? cookieJar;

  /// Callback invoked when the auth interceptor sees a 401 from a non-login
  /// path. Typical use: flip the app's auth state to "unauthenticated" so
  /// the router redirects to the login screen.
  final OnUnauthorized? onUnauthorized;

  /// Paths whose 401 must NOT trigger [onUnauthorized] — typically the
  /// login POST itself (where 401 = "wrong password") and 2FA verification
  /// endpoints.
  final List<LoginPathRule> loginPaths;

  /// Retry policy. Pass [RetryPolicy.defaultPolicy] (the default) for the
  /// standard 2-retry exponential-backoff strategy.
  final RetryPolicy retryPolicy;

  /// Path suffix the audit interceptor uses to identify the
  /// login + session-validate endpoint. Most Eden products use the Rails
  /// Devise convention `/api/v1/session`.
  final String auditLoginPath;

  /// Tag prepended to audit log lines (e.g. `[AuthAudit-AODex]`).
  final String auditLogTag;

  /// If true, attaches the Sentry Dio integration so requests appear as
  /// breadcrumbs and HTTP spans under the current Sentry transaction.
  /// No-ops if the Sentry SDK isn't initialized.
  final bool enableSentry;

  /// If true, attaches a debug-only [LogInterceptor] (gated on `kDebugMode`
  /// — release builds never pay the serialize cost).
  final bool enableDebugLogging;
}
