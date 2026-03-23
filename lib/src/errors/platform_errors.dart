/// Typed error hierarchy for Eden platform operations.
///
/// Use these types to distinguish between network failures, authentication
/// failures, and server errors in catch blocks.
sealed class PlatformError implements Exception {
  final String message;
  final Object? cause;

  PlatformError(this.message, {this.cause});

  @override
  String toString() => '$runtimeType: $message';
}

/// Connection failures, timeouts, and other network-related errors.
class NetworkError extends PlatformError {
  NetworkError(super.message, {super.cause});
}

/// Authentication or authorization failures (expired tokens, invalid
/// credentials, insufficient permissions).
class AuthError extends PlatformError {
  AuthError(super.message, {super.cause});
}

/// Server-side errors with an optional ConnectRPC status code.
class ServerError extends PlatformError {
  final int? code;

  ServerError(super.message, {this.code, super.cause});

  @override
  String toString() => 'ServerError($code): $message';
}
