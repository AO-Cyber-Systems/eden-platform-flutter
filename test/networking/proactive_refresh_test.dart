import 'dart:convert';

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// JWT helpers
// ---------------------------------------------------------------------------

/// Builds a minimal, UNSIGNED JWT with the given [exp] Unix timestamp.
/// The signature is replaced with 'fakesig' so there is no real key needed —
/// [JWT.decode] (used inside [ProactiveRefresh]) skips signature verification
/// and only decodes the payload.
String _buildJwt({int? exp}) {
  final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
  final Map<String, Object?> payloadMap = {};
  if (exp != null) payloadMap['exp'] = exp;
  final payload =
      base64Url.encode(utf8.encode(jsonEncode(payloadMap)));
  return '$header.$payload.fakesig';
}

/// Returns a Unix timestamp [offset] from now (can be negative for past).
int _expAt(Duration offset) =>
    (DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000) +
    offset.inSeconds;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ProactiveRefresh.refreshIfNeeded', () {
    test('no-ops when accessToken is null', () async {
      int calls = 0;
      final pr = ProactiveRefresh(
        getAccessToken: () => null,
        restoreSession: () async => calls++,
      );

      await pr.refreshIfNeeded();

      expect(calls, 0, reason: 'null token → no refresh');
    });

    test('no-ops when JWT has no exp claim', () async {
      int calls = 0;
      final noExpJwt = _buildJwt(); // no exp
      final pr = ProactiveRefresh(
        getAccessToken: () => noExpJwt,
        restoreSession: () async => calls++,
      );

      await pr.refreshIfNeeded();

      expect(calls, 0, reason: 'missing exp → no refresh');
    });

    test('no-ops when JWT is malformed', () async {
      int calls = 0;
      final pr = ProactiveRefresh(
        getAccessToken: () => 'not.a.jwt',
        restoreSession: () async => calls++,
      );

      await pr.refreshIfNeeded();

      expect(calls, 0, reason: 'malformed JWT → no refresh, no throw');
    });

    test('no-ops when token has more than threshold remaining', () async {
      int calls = 0;
      final freshJwt = _buildJwt(exp: _expAt(const Duration(minutes: 10)));
      final pr = ProactiveRefresh(
        getAccessToken: () => freshJwt,
        restoreSession: () async => calls++,
        threshold: const Duration(minutes: 2),
      );

      await pr.refreshIfNeeded();

      expect(calls, 0, reason: '>2 min remaining → still fresh');
    });

    test('refreshes when token exp is within threshold', () async {
      int calls = 0;
      final almostExpiredJwt =
          _buildJwt(exp: _expAt(const Duration(seconds: 30)));
      final pr = ProactiveRefresh(
        getAccessToken: () => almostExpiredJwt,
        restoreSession: () async => calls++,
        threshold: const Duration(minutes: 2),
      );

      await pr.refreshIfNeeded();

      expect(calls, 1, reason: '<2 min remaining → should refresh');
    });

    test('refreshes when token is already expired', () async {
      int calls = 0;
      final expiredJwt =
          _buildJwt(exp: _expAt(const Duration(minutes: -5)));
      final pr = ProactiveRefresh(
        getAccessToken: () => expiredJwt,
        restoreSession: () async => calls++,
      );

      await pr.refreshIfNeeded();

      expect(calls, 1, reason: 'past expiry → should refresh');
    });

    test('single-flight: concurrent calls collapse to one refresh', () async {
      int calls = 0;
      final almostExpiredJwt =
          _buildJwt(exp: _expAt(const Duration(seconds: 10)));

      final pr = ProactiveRefresh(
        getAccessToken: () => almostExpiredJwt,
        restoreSession: () async {
          calls++;
          // Simulate async work so concurrent calls have something to attach
          // to.
          await Future<void>.delayed(const Duration(milliseconds: 10));
        },
      );

      // Fire three concurrent calls.
      await Future.wait([
        pr.refreshIfNeeded(),
        pr.refreshIfNeeded(),
        pr.refreshIfNeeded(),
      ]);

      expect(calls, 1,
          reason: 'all concurrent callers should share the single in-flight');
    });

    test('inflight slot cleared after success — next call can re-refresh',
        () async {
      int calls = 0;
      final almostExpiredJwt =
          _buildJwt(exp: _expAt(const Duration(seconds: 10)));

      final pr = ProactiveRefresh(
        getAccessToken: () => almostExpiredJwt,
        restoreSession: () async => calls++,
      );

      await pr.refreshIfNeeded();
      await pr.refreshIfNeeded();

      expect(calls, 2,
          reason: 'after first completes, slot clears → second can refresh');
    });

    test('restoreSession error propagates to caller, slot is cleared',
        () async {
      int calls = 0;
      final almostExpiredJwt =
          _buildJwt(exp: _expAt(const Duration(seconds: 10)));

      final pr = ProactiveRefresh(
        getAccessToken: () => almostExpiredJwt,
        restoreSession: () async {
          calls++;
          throw Exception('refresh network error');
        },
      );

      expect(
        pr.refreshIfNeeded(),
        throwsA(isA<Exception>()),
      );

      // After the error, inflight slot must be cleared so a subsequent call
      // can retry.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // A fresh call on an expired token should attempt again.
      expect(calls, 1);
    });

    test('custom threshold respected', () async {
      int calls = 0;
      // Token expiring in 4 minutes.
      final jwt = _buildJwt(exp: _expAt(const Duration(minutes: 4)));
      final pr = ProactiveRefresh(
        getAccessToken: () => jwt,
        restoreSession: () async => calls++,
        // Use a 5-minute threshold → 4-minute token is within threshold.
        threshold: const Duration(minutes: 5),
      );

      await pr.refreshIfNeeded();

      expect(calls, 1, reason: '4 min < 5 min threshold → refresh triggered');
    });
  });

  group('onAppResumeCallProactiveRefresh', () {
    test('fires-and-forgets refresh without throwing', () async {
      int calls = 0;
      final almostExpiredJwt =
          _buildJwt(exp: _expAt(const Duration(seconds: 30)));

      final pr = ProactiveRefresh(
        getAccessToken: () => almostExpiredJwt,
        restoreSession: () async => calls++,
      );

      // Should not throw, even though it is fire-and-forget.
      onAppResumeCallProactiveRefresh(pr);

      // Allow the microtask queue to drain.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(calls, 1);
    });

    test('swallows errors from restoreSession on resume', () async {
      final almostExpiredJwt =
          _buildJwt(exp: _expAt(const Duration(seconds: 30)));

      final pr = ProactiveRefresh(
        getAccessToken: () => almostExpiredJwt,
        restoreSession: () async => throw Exception('network error'),
      );

      // Must not throw — errors are swallowed (fire-and-forget).
      expect(
        () => onAppResumeCallProactiveRefresh(pr),
        returnsNormally,
      );

      // Drain the microtask queue — should not cause unhandled exception.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
  });
}
