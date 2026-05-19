// Copyright 2026 AOCyber. All rights reserved.
//
// ConnectCookieInterceptor — attaches the cookie jar's stored cookies to
// outgoing Connect-RPC requests and persists Set-Cookie from responses
// back to the jar.
//
// Platform behavior:
// - **Web (kIsWeb=true):** No-op. The browser's same-origin cookie policy
//   handles request/response cookies automatically once the underlying
//   fetch is invoked with credentials included. Wiring a Dart-side cookie
//   manager on web would in fact double-handle Set-Cookie and risk
//   collisions with the browser's own jar.
// - **Native (kIsWeb=false):** Reads cookies for the request URL from the
//   shared `cookieJar` (see cookie_jar_helper.dart) and writes them to
//   the outgoing `Cookie` header. After the response, parses any
//   `Set-Cookie` headers and saves them back to the jar so subsequent
//   requests carry the updated session.
//
// Usage (consumer side):
// ```dart
// final transport = createPlatformTransport(
//   baseUrl: baseUrl,
//   interceptors: [connectCookieInterceptor()],
// );
// ```
//
// The interceptor reads the global `cookieJar`. Consumers must call
// `initCookieJar(storagePath)` (native) or `initCookieJarWeb()` (web)
// before constructing any transport that uses this interceptor.

import 'package:connectrpc/connect.dart' as connect;
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

import 'cookie_jar_helper.dart' as helper;

/// Returns an [connect.Interceptor] that reads/writes cookies via the
/// shared cookie jar on native, and is a no-op on web.
///
/// On native, before each request: reads cookies for the request URL from
/// [helper.cookieJar] and joins them into a `Cookie:` header. After the
/// response: parses each `Set-Cookie` (or its lower-case variant) header
/// and persists the cookies back to the jar.
connect.Interceptor connectCookieInterceptor() {
  if (kIsWeb) {
    return _noopInterceptor();
  }
  return _cookieInterceptorImpl(() => helper.cookieJar);
}

/// Test-visible factory: returns the same native-mode interceptor as
/// [connectCookieInterceptor] but with an injectable [jarReader] so tests
/// don't need to initialize the global cookie jar. The injected reader is
/// resolved per-request to allow mid-test jar mutation.
@visibleForTesting
connect.Interceptor connectCookieInterceptorForTest({
  required CookieJar Function() jarReader,
}) {
  return _cookieInterceptorImpl(jarReader);
}

/// Test-visible factory for the web no-op variant. Exposed so the web
/// branch can be exercised even on a non-web test platform.
@visibleForTesting
connect.Interceptor connectCookieInterceptorWebForTest() {
  return _noopInterceptor();
}

connect.Interceptor _noopInterceptor() {
  return <I extends Object, O extends Object>(connect.AnyFn<I, O> next) {
    return (connect.Request<I, O> request) async {
      // Web: the browser owns the cookie store. Pass the request through
      // untouched.
      return next(request);
    };
  };
}

connect.Interceptor _cookieInterceptorImpl(CookieJar Function() jarReader) {
  return <I extends Object, O extends Object>(connect.AnyFn<I, O> next) {
    return (connect.Request<I, O> request) async {
      final jar = jarReader();
      final uri = Uri.parse(request.url);

      // Outbound: assemble a Cookie header from the jar.
      final cookies = await jar.loadForRequest(uri);
      if (cookies.isNotEmpty) {
        final cookieValue =
            cookies.map((c) => '${c.name}=${c.value}').join('; ');
        request.headers['cookie'] = cookieValue;
      }

      final response = await next(request);

      // Inbound: persist any Set-Cookie headers back to the jar. The
      // connectrpc Headers map is case-sensitive; servers may send either
      // 'Set-Cookie' or 'set-cookie' depending on transport (HTTP/1.1
      // typically normalizes to lower-case, HTTP/2 lower-cases everything).
      final setCookieValues = <String>[];
      for (final entry in response.headers.entries) {
        if (entry.name.toLowerCase() == 'set-cookie') {
          setCookieValues.add(entry.value);
        }
      }
      // Also inspect trailers (Connect protocol attaches them at end of
      // response) — though Set-Cookie should appear in headers, not
      // trailers. Cheap to check; safer than missing one.
      for (final entry in response.trailers.entries) {
        if (entry.name.toLowerCase() == 'set-cookie') {
          setCookieValues.add(entry.value);
        }
      }

      if (setCookieValues.isNotEmpty) {
        final parsed = setCookieValues
            .map((raw) => Cookie.fromSetCookieValue(raw))
            .toList();
        await jar.saveFromResponse(uri, parsed);
      }

      return response;
    };
  };
}
