import 'package:dio/dio.dart';
import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Default rule set: covers the canonical Eden / Rails Devise flow.
  // Apps that diverge pass their own list at construction time.
  const defaultRules = [
    LoginPathRule.exact('POST', '/api/v1/session'),
    LoginPathRule.exact('POST', '/api/v1/auth/oauth'),
    LoginPathRule.exact('POST', '/api/v1/session/verify_totp'),
    LoginPathRule.exact('POST', '/api/v1/session/verify_email_otp'),
    LoginPathRule.contains('GET', '/insights'),
  ];

  late AuthInterceptor interceptor;
  late List<String> unauthorizedPaths;

  setUp(() {
    unauthorizedPaths = <String>[];
    interceptor = AuthInterceptor(
      onUnauthorized: (path) => unauthorizedPaths.add(path),
      loginPaths: defaultRules,
    );
  });

  DioException buildError({
    required String path,
    required int? statusCode,
    String method = 'GET',
  }) {
    final options = RequestOptions(path: path, method: method);
    return DioException(
      requestOptions: options,
      response: statusCode == null
          ? null
          : Response(requestOptions: options, statusCode: statusCode),
    );
  }

  group('onError', () {
    test('notifies on 401 from an authed endpoint', () async {
      final handler = _MockErrorInterceptorHandler();
      await interceptor.onError(
        buildError(path: '/api/v1/profile', statusCode: 401),
        handler,
      );

      expect(handler.nextCalled, isTrue);
      expect(unauthorizedPaths, ['/api/v1/profile']);
    });

    test('does not notify on non-401 errors', () async {
      final handler = _MockErrorInterceptorHandler();
      await interceptor.onError(
        buildError(path: '/api/v1/test', statusCode: 500),
        handler,
      );

      expect(handler.nextCalled, isTrue);
      expect(unauthorizedPaths, isEmpty);
    });

    test('does not notify on 401 from POST /api/v1/session (login wrong password)',
        () async {
      final handler = _MockErrorInterceptorHandler();
      await interceptor.onError(
        buildError(
          path: '/api/v1/session',
          statusCode: 401,
          method: 'POST',
        ),
        handler,
      );

      expect(handler.nextCalled, isTrue);
      expect(unauthorizedPaths, isEmpty,
          reason: 'login POST 401 must not fire onUnauthorized');
    });

    test('does not notify on 401 from POST /api/v1/auth/oauth', () async {
      final handler = _MockErrorInterceptorHandler();
      await interceptor.onError(
        buildError(
          path: '/api/v1/auth/oauth',
          statusCode: 401,
          method: 'POST',
        ),
        handler,
      );

      expect(handler.nextCalled, isTrue);
      expect(unauthorizedPaths, isEmpty);
    });

    test('does not notify on 401 from POST /api/v1/session/verify_totp',
        () async {
      final handler = _MockErrorInterceptorHandler();
      await interceptor.onError(
        buildError(
          path: '/api/v1/session/verify_totp',
          statusCode: 401,
          method: 'POST',
        ),
        handler,
      );

      expect(handler.nextCalled, isTrue);
      expect(unauthorizedPaths, isEmpty);
    });

    test('does not notify on 401 from POST /api/v1/session/verify_email_otp',
        () async {
      final handler = _MockErrorInterceptorHandler();
      await interceptor.onError(
        buildError(
          path: '/api/v1/session/verify_email_otp',
          statusCode: 401,
          method: 'POST',
        ),
        handler,
      );

      expect(handler.nextCalled, isTrue);
      expect(unauthorizedPaths, isEmpty);
    });

    test('401 from GET insights does NOT trigger logout (parameterised path)',
        () async {
      final handler = _MockErrorInterceptorHandler();
      await interceptor.onError(
        buildError(
          path: '/api/v1/conversations/123/messages/456/insights',
          statusCode: 401,
          method: 'GET',
        ),
        handler,
      );

      expect(handler.nextCalled, isTrue);
      expect(unauthorizedPaths, isEmpty,
          reason: 'GET insights 401 must not fire onUnauthorized');
    });

    test('POST to a path containing /insights still triggers logout', () async {
      final handler = _MockErrorInterceptorHandler();
      const path = '/api/v1/conversations/123/messages/456/insights';
      await interceptor.onError(
        buildError(path: path, statusCode: 401, method: 'POST'),
        handler,
      );

      expect(handler.nextCalled, isTrue);
      expect(unauthorizedPaths, contains(path),
          reason: 'POST to insights path is not exempt and must trigger logout');
    });

    test('notifies on 401 from GET /api/v1/session (session validate)',
        () async {
      final handler = _MockErrorInterceptorHandler();
      await interceptor.onError(
        buildError(
          path: '/api/v1/session',
          statusCode: 401,
          method: 'GET',
        ),
        handler,
      );

      expect(handler.nextCalled, isTrue);
      expect(unauthorizedPaths, ['/api/v1/session']);
    });

    test('empty loginPaths means every 401 fires onUnauthorized', () async {
      final emptyInterceptor = AuthInterceptor(
        onUnauthorized: (path) => unauthorizedPaths.add(path),
        loginPaths: const [],
      );

      final handler = _MockErrorInterceptorHandler();
      await emptyInterceptor.onError(
        buildError(path: '/api/v1/session', statusCode: 401, method: 'POST'),
        handler,
      );

      expect(unauthorizedPaths, ['/api/v1/session'],
          reason: 'with no rules, even login POST 401 fires the callback');
    });

    test('null onUnauthorized is silently ignored', () async {
      final silentInterceptor = AuthInterceptor(
        onUnauthorized: null,
        loginPaths: defaultRules,
      );

      final handler = _MockErrorInterceptorHandler();
      await silentInterceptor.onError(
        buildError(path: '/api/v1/profile', statusCode: 401),
        handler,
      );

      expect(handler.nextCalled, isTrue,
          reason: 'must still call next() even with no callback');
    });
  });

  group('isLoginPath', () {
    test('POST /api/v1/session matches', () {
      expect(interceptor.isLoginPath('/api/v1/session', 'POST'), isTrue);
    });
    test('GET /api/v1/session does NOT match (only POST is login)', () {
      expect(interceptor.isLoginPath('/api/v1/session', 'GET'), isFalse);
    });
    test('case-insensitive method', () {
      expect(interceptor.isLoginPath('/api/v1/session', 'post'), isTrue);
    });
    test('DELETE /api/v1/session (signout) does NOT match', () {
      expect(interceptor.isLoginPath('/api/v1/session', 'DELETE'), isFalse);
    });
    test('unrelated path does not match', () {
      expect(interceptor.isLoginPath('/api/v1/profile', 'GET'), isFalse);
    });
    test('GET */insights matches (contains rule)', () {
      expect(
        interceptor.isLoginPath(
          '/api/v1/conversations/x/messages/y/insights',
          'GET',
        ),
        isTrue,
      );
    });
    test('POST */insights does NOT match (only GET is exempt)', () {
      expect(
        interceptor.isLoginPath(
          '/api/v1/conversations/x/messages/y/insights',
          'POST',
        ),
        isFalse,
      );
    });
    test('null method does not match', () {
      expect(interceptor.isLoginPath('/api/v1/session', null), isFalse);
    });
  });
}

class _MockErrorInterceptorHandler extends ErrorInterceptorHandler {
  bool nextCalled = false;
  DioException? nextError;

  @override
  void next(DioException err) {
    nextCalled = true;
    nextError = err;
  }
}
