# eden_platform_flutter networking

Shared HTTP + WebSocket client for every Eden Flutter app. Ports the
gold-standard `dio_client` from AODex Flutter (cookies, retry, audit,
auth-refresh) and parameterises it for product-specific config.

This kills five-plus forks of nearly-identical Dio wiring across the
portfolio (AODex, AOFamily ×3, AOSentry-admin, justforme, etc).

## Quick start

```dart
import 'package:eden_platform_flutter/eden_platform.dart' as platform;
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Initialize the cookie jar before building the Dio.
//   - Native: pass the app's Documents directory.
//   - Web: call initCookieJarWeb(); the browser owns cookies via CORS.
await platform.initCookieJar(appDocumentsPath);

final dio = platform.DioClientFactory.create(
  platform.DioClientConfig(
    baseUrl: 'https://api.example.com',
    cookieJar: platform.cookieJar,
    onUnauthorized: (path) {
      // Flip your app to the unauthenticated state.
      authNotifier.forceUnauthenticated();
    },
    loginPaths: const [
      // 401 from these paths means "wrong password" / "wrong code", NOT
      // "session expired" — don't trigger the global sign-out callback.
      platform.LoginPathRule.exact('POST', '/api/v1/session'),
      platform.LoginPathRule.exact('POST', '/api/v1/auth/oauth'),
      platform.LoginPathRule.exact('POST', '/api/v1/session/verify_totp'),
      platform.LoginPathRule.contains('GET', '/insights'),
    ],
  ),
);
```

## Interceptor chain

The factory wires interceptors in this order. The order matters because
Dio runs request interceptors top-to-bottom and response/error interceptors
bottom-to-top.

| # | Interceptor | Purpose |
|---|---|---|
| 1 | `AuthAuditInterceptor` | First so it sees raw responses before any other interceptor mutates them. Logs auth-relevant signals (401 on authed endpoints, missing CORS headers, login response shape) without ever logging cookie values, request bodies, or authorization headers. |
| 2 | `CookieManager` (native only) | Persists session cookies across app restarts. Skipped on web — the browser owns the cookie jar via CORS. |
| 3 | `RetryInterceptor` | Registered before `AuthInterceptor` so transient 5xx retries finish before the auth flow sees a final failure. Only retries idempotent methods (GET/HEAD/OPTIONS) on 5xx + network errors, max 2 retries, exponential backoff from 500 ms. **4xx is terminal — never retried.** |
| 4 | `AuthInterceptor` | Converts 401 from non-login endpoints into the `onUnauthorized` callback so the app can flip its auth state to unauthenticated. The 2FA / login POST / OAuth exchange endpoints are exempt via `loginPaths`. |
| 5 | `LogInterceptor` (debug only) | Gated on `kDebugMode` — release builds never pay the serialize cost. Cookies are redacted in the output. Disable globally via `enableDebugLogging: false`. |
| 6 | `Sentry Dio` | Breadcrumbs + HTTP spans for every request. No-ops if Sentry isn't initialized. Disable via `enableSentry: false`. |

## Retry policy

| Condition | Retried? |
|---|---|
| 4xx response | **Never.** Client errors are terminal. |
| 5xx response on GET/HEAD/OPTIONS | Yes, max 2 retries. |
| 5xx response on POST/PATCH/PUT/DELETE | **Never** by default. Risk of double-submit. |
| Network error (timeout, connection drop, DNS fail) on GET/HEAD/OPTIONS | Yes, max 2 retries. |
| Bad cert / cancelled / unknown | Never. |

Backoff is exponential starting at 500 ms (so retries land at 500 ms, 1 s).
Override via `RetryPolicy(maxRetries: 3, initialDelay: Duration(seconds: 1))`.

## Wiring your auth callback

The `onUnauthorized` callback fires when the server returns 401 from a path
that ISN'T in `loginPaths`. Typical pattern (Riverpod):

```dart
@Riverpod(keepAlive: true)
Dio dioClient(Ref ref) {
  return platform.DioClientFactory.create(
    platform.DioClientConfig(
      baseUrl: ApiConfig.baseUrl,
      onUnauthorized: (path) =>
          ref.read(authServiceProvider.notifier).forceUnauthenticated(),
      loginPaths: const [...],
    ),
  );
}
```

Use a lazy `ref.read` inside the callback — NOT inside the `DioClientConfig`
literal — to avoid a provider init cycle if your `authServiceProvider`
itself depends on `dioClientProvider`.

## `loginPaths` rules

`LoginPathRule` has two match modes:

- `LoginPathRule.exact(method, pattern)` — match when method matches and
  `path.endsWith(pattern)`. Use for canonical endpoints like
  `POST /api/v1/session`.
- `LoginPathRule.contains(method, pattern)` — match when method matches
  and `path.contains(pattern)`. Use for parameterised paths like
  `GET /api/v1/conversations/{id}/messages/{msgId}/insights`.

Method matching is case-insensitive.

## ApiException

Translate any `DioException` into a typed sealed class:

```dart
try {
  await dio.get('/api/v1/profile');
} on DioException catch (e) {
  final apiError = ApiException.fromDioException(e);
  switch (apiError) {
    case NetworkException():
      showOfflineSnack();
    case TimeoutException():
      showRetryDialog();
    case UnauthorizedException(:final message):
      // Auth interceptor has already triggered the callback; just show
      // the user-facing message here.
      showSnack(message ?? apiError.userMessage);
    case PaymentRequiredException():
      showUpgradeDialog();
    case ForbiddenException(:final message):
      showError(message ?? 'No permission');
    case BadRequestException(:final message):
      showError(message);
    case ServerErrorException():
      showRetryDialog();
    case UnknownException(:final message):
      showError(message);
  }
}
```

Server-side error message extraction recognises both Rails (`{errors: [...]}`)
and generic JSON (`{error: '...'}`) conventions.

## WebSocket factory

```dart
final channel = platform.createWebSocketChannel(
  'wss://api.example.com/cable',
  protocols: ['actioncable-v1-json'],  // Rails ActionCable subprotocol
  pingInterval: const Duration(seconds: 3),
);
```

The conditional-import bridge picks the right implementation:

- **Native (`dart:io`)** — `IOWebSocketChannel.connect` with cookie
  headers + ping interval.
- **Web (`dart:js_interop`)** — browser `WebSocketChannel.connect`. Cookies
  are sent automatically for same-origin requests (the `headers` argument
  is ignored). Ping interval is also ignored — the browser handles pings.

## Migration from a forked DioClient

Products with their own Dio fork (AODex, AOFamily ×3, AOSentry-admin) should:

1. Add `eden_platform_flutter` to `pubspec.yaml`.
2. Replace local `dio_client.dart` factory with a thin Riverpod wrapper that
   calls `DioClientFactory.create(DioClientConfig(...))`.
3. Pass product-specific config via `DioClientConfig`:
   - `baseUrl` — your `ApiConfig.baseUrl`.
   - `loginPaths` — your product's login + 2FA endpoints.
   - `onUnauthorized` — your auth notifier's "force sign-out" method.
   - `auditLoginPath` — usually `/api/v1/session` (default).
4. Delete local `auth_interceptor.dart`, `retry_interceptor.dart`,
   `auth_audit_interceptor.dart`, `api_exception.dart`, and WebSocket
   factory files. Update consumers to import from
   `package:eden_platform_flutter/eden_platform.dart`.

## Test coverage

- `auth_interceptor_test.dart` — 14 cases covering exact-match exemptions,
  contains-match exemptions, method case-insensitivity, and the canonical
  401 → `onUnauthorized` path.
- `retry_interceptor_test.dart` — 6 cases covering 4xx terminal,
  5xx retry, recovery on retry, POST never retried, custom `maxRetries=0`.
- `auth_audit_interceptor_test.dart` — 6 cases covering login-response
  logging (with set-cookie redaction), session-validate logging,
  401 + 403 logging, non-auth-endpoint silence, 5xx silence.
- `api_exception_test.dart` — every status code → variant mapping plus
  Rails / generic message-extraction.
- `dio_client_factory_test.dart` — interceptor chain order + base options
  smoke test.
