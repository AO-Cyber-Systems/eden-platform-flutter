import 'dart:io';

import 'package:dio/dio.dart';
import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_test/flutter_test.dart';

/// Subclass that captures log calls instead of printing them, to assert
/// that the audit interceptor emits the expected signal lines under each
/// scenario. Mirrors the production interceptor's gate logic exactly.
class _TestableAuthAuditInterceptor extends AuthAuditInterceptor {
  _TestableAuthAuditInterceptor({super.loginPath, super.logTag});

  final List<String> logs = [];

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final status = response.statusCode ?? 0;
    final path = response.requestOptions.path;
    final method = response.requestOptions.method;

    if (method == 'POST' && path.endsWith(loginPath)) {
      final headers = response.headers;
      logs.add(
        'login status=$status '
        'has_set_cookie=${headers.value("set-cookie") != null} '
        'has_ws_token=${response.data is Map && response.data["ws_token"] != null}',
      );
    }

    if (method == 'GET' && path.endsWith(loginPath)) {
      logs.add('validate status=$status');
    }

    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final status = err.response?.statusCode;
    final path = err.requestOptions.path;
    final method = err.requestOptions.method;

    if (status == 401 || status == 403) {
      logs.add('$status on $method $path');
    } else if (err.type == DioExceptionType.connectionError ||
        err.type == DioExceptionType.unknown) {
      logs.add('connection_error on $method $path');
    }

    handler.next(err);
  }
}

void main() {
  late Dio dio;
  late HttpServer server;
  late _TestableAuthAuditInterceptor interceptor;
  late String baseUrl;

  setUp(() async {
    interceptor = _TestableAuthAuditInterceptor();

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://localhost:${server.port}';

    dio = Dio(BaseOptions(baseUrl: baseUrl));
    dio.interceptors.add(interceptor);
  });

  tearDown(() async {
    dio.close();
    await server.close();
  });

  test('logs login response metadata', () async {
    server.listen((req) {
      req.response
        ..statusCode = 200
        ..headers.set('content-type', 'application/json')
        ..headers
            .set('set-cookie', '_aocodex_session=SECRET; HttpOnly; Path=/')
        ..write('{"user":{"id":"1"},"ws_token":"SECRET_WS"}')
        ..close();
    });

    await dio.post('/api/v1/session', data: {});

    expect(interceptor.logs, hasLength(1));
    expect(interceptor.logs.first, contains('has_set_cookie=true'));
    expect(interceptor.logs.first, contains('has_ws_token=true'));
    expect(interceptor.logs.first, contains('status=200'));
    // Must not contain actual secrets
    expect(interceptor.logs.first, isNot(contains('SECRET')));
  });

  test('logs login response without ws_token', () async {
    server.listen((req) {
      req.response
        ..statusCode = 200
        ..headers.set('content-type', 'application/json')
        ..write('{"user":{"id":"1"}}')
        ..close();
    });

    await dio.post('/api/v1/session', data: {});

    expect(interceptor.logs, hasLength(1));
    expect(interceptor.logs.first, contains('has_ws_token=false'));
  });

  test('logs session validate', () async {
    server.listen((req) {
      req.response
        ..statusCode = 200
        ..headers.set('content-type', 'application/json')
        ..write('{"user":{"id":"1"}}')
        ..close();
    });

    await dio.get('/api/v1/session');

    expect(interceptor.logs, hasLength(1));
    expect(interceptor.logs.first, contains('validate status=200'));
  });

  test('does not log non-auth endpoints', () async {
    server.listen((req) {
      req.response
        ..statusCode = 200
        ..headers.set('content-type', 'application/json')
        ..write('[]')
        ..close();
    });

    await dio.get('/api/v1/conversations');

    expect(interceptor.logs, isEmpty);
  });

  test('logs 401 errors', () async {
    server.listen((req) {
      req.response
        ..statusCode = 401
        ..headers.set('content-type', 'application/json')
        ..write('{"error":"Unauthorized"}')
        ..close();
    });

    try {
      await dio.get('/api/v1/conversations');
    } on DioException {
      // expected
    }

    expect(interceptor.logs, hasLength(1));
    expect(interceptor.logs.first, contains('401'));
    expect(interceptor.logs.first, contains('GET'));
    expect(interceptor.logs.first, contains('/api/v1/conversations'));
  });

  test('does not log 500 errors', () async {
    server.listen((req) {
      req.response
        ..statusCode = 500
        ..headers.set('content-type', 'application/json')
        ..write('{"error":"Internal"}')
        ..close();
    });

    try {
      await dio.get('/api/v1/conversations');
    } on DioException {
      // expected
    }

    expect(interceptor.logs, isEmpty);
  });

  test('respects custom loginPath when supplied', () async {
    final customDio = Dio(BaseOptions(baseUrl: baseUrl));
    final customInterceptor = _TestableAuthAuditInterceptor(
      loginPath: '/v2/login',
      logTag: 'AuthAudit-Custom',
    );
    customDio.interceptors.add(customInterceptor);

    server.listen((req) {
      req.response
        ..statusCode = 200
        ..headers.set('content-type', 'application/json')
        ..write('{"user":{"id":"1"}}')
        ..close();
    });

    await customDio.post('/v2/login', data: {});
    customDio.close();

    expect(customInterceptor.logs, hasLength(1));
    expect(customInterceptor.logs.first, contains('login status=200'));
  });
}
