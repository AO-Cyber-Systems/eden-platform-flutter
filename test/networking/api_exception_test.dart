import 'package:dio/dio.dart';
import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  RequestOptions ro() => RequestOptions(path: '/test');

  group('ApiException.fromDioException', () {
    test('connectionTimeout -> timeout', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.connectionTimeout,
      );
      expect(ApiException.fromDioException(e), isA<TimeoutException>());
    });

    test('sendTimeout -> timeout', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.sendTimeout,
      );
      expect(ApiException.fromDioException(e), isA<TimeoutException>());
    });

    test('receiveTimeout -> timeout', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.receiveTimeout,
      );
      expect(ApiException.fromDioException(e), isA<TimeoutException>());
    });

    test('connectionError -> network', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.connectionError,
      );
      expect(ApiException.fromDioException(e), isA<NetworkException>());
    });

    test('badCertificate -> network', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.badCertificate,
      );
      expect(ApiException.fromDioException(e), isA<NetworkException>());
    });

    test('cancel -> unknown', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.cancel,
      );
      final mapped = ApiException.fromDioException(e);
      expect(mapped, isA<UnknownException>());
      expect((mapped as UnknownException).message, 'Request cancelled');
    });

    test('401 -> unauthorized with extracted Rails error', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: ro(),
          statusCode: 401,
          data: {'errors': ['Bad password', 'Locked']},
        ),
      );
      final mapped = ApiException.fromDioException(e);
      expect(mapped, isA<UnauthorizedException>());
      expect((mapped as UnauthorizedException).message, 'Bad password, Locked');
    });

    test('401 -> unauthorized with extracted generic error', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: ro(),
          statusCode: 401,
          data: {'error': 'Token expired'},
        ),
      );
      final mapped = ApiException.fromDioException(e);
      expect(mapped, isA<UnauthorizedException>());
      expect((mapped as UnauthorizedException).message, 'Token expired');
    });

    test('402 -> paymentRequired', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: ro(),
          statusCode: 402,
          data: {'error': 'Out of credits'},
        ),
      );
      final mapped = ApiException.fromDioException(e);
      expect(mapped, isA<PaymentRequiredException>());
      expect((mapped as PaymentRequiredException).message, 'Out of credits');
    });

    test('403 -> forbidden', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: ro(),
          statusCode: 403,
          data: {'error': 'No access'},
        ),
      );
      final mapped = ApiException.fromDioException(e);
      expect(mapped, isA<ForbiddenException>());
      expect((mapped as ForbiddenException).message, 'No access');
    });

    test('400 -> badRequest', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: ro(),
          statusCode: 400,
          data: {'errors': ['Bad input']},
        ),
      );
      final mapped = ApiException.fromDioException(e);
      expect(mapped, isA<BadRequestException>());
      expect((mapped as BadRequestException).message, 'Bad input');
    });

    test('422 -> badRequest', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: ro(),
          statusCode: 422,
          data: {'errors': ['Email is required']},
        ),
      );
      expect(
        ApiException.fromDioException(e),
        isA<BadRequestException>(),
      );
    });

    test('413 -> badRequest with "Payload too large" fallback', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.badResponse,
        response: Response(
          requestOptions: ro(),
          statusCode: 413,
          data: const <String, dynamic>{},
        ),
      );
      final mapped = ApiException.fromDioException(e);
      expect(mapped, isA<BadRequestException>());
      expect((mapped as BadRequestException).message, 'Payload too large');
    });

    test('500 -> serverError', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: ro(), statusCode: 500),
      );
      expect(ApiException.fromDioException(e), isA<ServerErrorException>());
    });

    test('503 -> serverError', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: ro(), statusCode: 503),
      );
      expect(ApiException.fromDioException(e), isA<ServerErrorException>());
    });

    test('418 (uncategorized non-5xx) -> unknown', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: ro(), statusCode: 418),
        message: 'I am a teapot',
      );
      final mapped = ApiException.fromDioException(e);
      expect(mapped, isA<UnknownException>());
      expect((mapped as UnknownException).message, contains('418'));
    });

    test('badResponse with null statusCode -> unknown', () {
      final e = DioException(
        requestOptions: ro(),
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: ro(), statusCode: null),
        message: 'no status',
      );
      expect(ApiException.fromDioException(e), isA<UnknownException>());
    });
  });

  group('userMessage', () {
    test('NetworkException', () {
      const e = ApiException.network();
      expect(e.userMessage, contains('No internet'));
    });
    test('TimeoutException', () {
      const e = ApiException.timeout();
      expect(e.userMessage, contains('timed out'));
    });
    test('UnauthorizedException with custom message', () {
      const e = ApiException.unauthorized('Bad creds');
      expect(e.userMessage, 'Bad creds');
    });
    test('UnauthorizedException without custom message', () {
      const e = ApiException.unauthorized();
      expect(e.userMessage, contains('Invalid'));
    });
    test('ForbiddenException default', () {
      const e = ApiException.forbidden();
      expect(e.userMessage, contains('permission'));
    });
    test('PaymentRequiredException default', () {
      const e = ApiException.paymentRequired();
      expect(e.userMessage, contains('credits'));
    });
    test('BadRequestException returns its message', () {
      const e = ApiException.badRequest('Field X required');
      expect(e.userMessage, 'Field X required');
    });
    test('ServerErrorException default', () {
      const e = ApiException.serverError();
      expect(e.userMessage, contains('Something went wrong'));
    });
    test('UnknownException default', () {
      const e = ApiException.unknown('Boom');
      expect(e.userMessage, contains('unexpected'));
    });
  });
}
