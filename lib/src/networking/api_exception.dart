import 'package:dio/dio.dart';

/// Sealed class representing API errors with typed variants.
///
/// Use [ApiException.fromDioException] to translate a [DioException] into
/// the appropriate variant. Pattern-match on the result with `switch (e) {}`.
sealed class ApiException implements Exception {
  const ApiException();

  /// Network connectivity error (no internet, DNS failure, etc.)
  const factory ApiException.network() = NetworkException;

  /// Request timed out.
  const factory ApiException.timeout() = TimeoutException;

  /// 401 Unauthorized - session expired or invalid credentials.
  const factory ApiException.unauthorized([String? message]) = UnauthorizedException;

  /// 402 Payment Required - credits exhausted, upgrade needed.
  const factory ApiException.paymentRequired([String? message]) = PaymentRequiredException;

  /// 403 Forbidden - authenticated but lacks required permission
  /// (e.g. non-org-admin hitting an admin-only resource).
  const factory ApiException.forbidden([String? message]) = ForbiddenException;

  /// 400/422 Bad request with a message from the server.
  const factory ApiException.badRequest(String message) = BadRequestException;

  /// 5xx Server error.
  const factory ApiException.serverError() = ServerErrorException;

  /// Unknown/unclassified error.
  const factory ApiException.unknown(String message) = UnknownException;

  /// Create an [ApiException] from a [DioException].
  factory ApiException.fromDioException(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const ApiException.timeout();

      case DioExceptionType.connectionError:
        return const ApiException.network();

      case DioExceptionType.badResponse:
        final statusCode = error.response?.statusCode;
        if (statusCode == null) {
          return ApiException.unknown(error.message ?? 'Unknown error');
        }

        if (statusCode == 401) {
          final data = error.response?.data;
          final message = _extractErrorMessage(data);
          return ApiException.unauthorized(message);
        }

        if (statusCode == 402) {
          final data = error.response?.data;
          final message = _extractErrorMessage(data);
          return ApiException.paymentRequired(message);
        }

        if (statusCode == 403) {
          final data = error.response?.data;
          final message = _extractErrorMessage(data);
          return ApiException.forbidden(message);
        }

        if (statusCode == 400 || statusCode == 422 || statusCode == 413) {
          final data = error.response?.data;
          final fallback =
              statusCode == 413 ? 'Payload too large' : 'Bad request';
          final message = _extractErrorMessage(data) ?? fallback;
          return ApiException.badRequest(message);
        }

        if (statusCode >= 500) {
          return const ApiException.serverError();
        }

        return ApiException.unknown(
          'HTTP $statusCode: ${error.message ?? "Unknown error"}',
        );

      case DioExceptionType.cancel:
        return const ApiException.unknown('Request cancelled');

      case DioExceptionType.badCertificate:
        return const ApiException.network();

      case DioExceptionType.unknown:
        return ApiException.unknown(error.message ?? 'Unknown error');
    }
  }

  /// Extract error message from API response body.
  ///
  /// Recognises two server conventions:
  /// - Rails: `{ "errors": ["..."] }`
  /// - Generic JSON: `{ "error": "..." }`
  static String? _extractErrorMessage(dynamic data) {
    if (data is Map<String, dynamic>) {
      // Rails error format: { "errors": ["..."] }
      final errors = data['errors'];
      if (errors is List && errors.isNotEmpty) {
        return errors.join(', ');
      }
      // Alternative format: { "error": "..." }
      final error = data['error'];
      if (error is String) {
        return error;
      }
    }
    return null;
  }

  /// User-friendly error message.
  String get userMessage;
}

class NetworkException extends ApiException {
  const NetworkException();

  @override
  String get userMessage => 'No internet connection. Please check your network.';

  @override
  String toString() => 'ApiException.network()';
}

class TimeoutException extends ApiException {
  const TimeoutException();

  @override
  String get userMessage => 'Request timed out. Please try again.';

  @override
  String toString() => 'ApiException.timeout()';
}

class UnauthorizedException extends ApiException {
  const UnauthorizedException([this.message]);

  final String? message;

  @override
  String get userMessage => message ?? 'Invalid email or password.';

  @override
  String toString() => 'ApiException.unauthorized($message)';
}

class ForbiddenException extends ApiException {
  const ForbiddenException([this.message]);

  final String? message;

  @override
  String get userMessage =>
      message ?? 'You do not have permission to view this resource.';

  @override
  String toString() => 'ApiException.forbidden($message)';
}

class BadRequestException extends ApiException {
  const BadRequestException(this.message);

  final String message;

  @override
  String get userMessage => message;

  @override
  String toString() => 'ApiException.badRequest($message)';
}

class ServerErrorException extends ApiException {
  const ServerErrorException();

  @override
  String get userMessage =>
      'Something went wrong on our end. Please try again later.';

  @override
  String toString() => 'ApiException.serverError()';
}

class UnknownException extends ApiException {
  const UnknownException(this.message);

  final String message;

  @override
  String get userMessage => 'An unexpected error occurred. Please try again.';

  @override
  String toString() => 'ApiException.unknown($message)';
}

class PaymentRequiredException extends ApiException {
  const PaymentRequiredException([this.message]);

  final String? message;

  @override
  String get userMessage =>
      message ?? "You've run out of credits. Upgrade your plan to continue.";

  @override
  String toString() => 'ApiException.paymentRequired($message)';
}
