import 'package:connectrpc/connect.dart' as connect;
import 'package:flutter/foundation.dart' show visibleForTesting;

/// A ConnectRPC [connect.Interceptor] that attaches
/// `Authorization: Bearer <token>` to every outgoing request.
///
/// The token is read lazily from [tokenReader] on each request, so token
/// rotation is automatically reflected in subsequent RPCs.
///
/// **No-op cases** (no header is attached):
/// - [tokenReader] returns null
/// - [tokenReader] returns an empty string
///
/// **Production usage** (Riverpod example):
/// ```dart
/// final myTransportProvider = Provider<connect.Transport>((ref) {
///   return protocol.Transport(
///     baseUrl: baseUrl,
///     codec: const JsonCodec(),
///     interceptors: [
///       connectBearerInterceptor(() => ref.read(authProvider).accessToken),
///     ],
///   );
/// });
/// ```
///
/// **Test usage:** use [connectBearerInterceptorForTest] instead — it accepts
/// a literal closure so tests don't need a `ProviderContainer`.
connect.Interceptor connectBearerInterceptor(
  String? Function() tokenReader,
) {
  return _bearerInterceptor(tokenReader);
}

/// Internal implementation shared by [connectBearerInterceptor] and
/// [connectBearerInterceptorForTest].
connect.Interceptor _bearerInterceptor(String? Function() tokenReader) {
  return <I extends Object, O extends Object>(connect.AnyFn<I, O> next) {
    return (connect.Request<I, O> request) async {
      final token = tokenReader();
      if (token != null && token.isNotEmpty) {
        request.headers['authorization'] = 'Bearer $token';
      }
      return next(request);
    };
  };
}

/// Test-visible factory: returns the same [connect.Interceptor] logic as
/// [connectBearerInterceptor] but accepts a literal [tokenReader] closure so
/// tests can compose the interceptor stack without a Riverpod `Ref`.
///
/// Always pair with a `tearDown` that restores real providers if the test
/// installs other side-effects.
///
/// ```dart
/// final interceptor = connectBearerInterceptorForTest(
///   tokenReader: () => 'fake-jwt-token',
/// );
/// final transport = FakeTransportBuilder()
///     .unary(mySpec, (req, ctx) => myResponse)
///     .build(interceptors: [interceptor]);
/// ```
@visibleForTesting
connect.Interceptor connectBearerInterceptorForTest({
  required String? Function() tokenReader,
}) {
  return _bearerInterceptor(tokenReader);
}
