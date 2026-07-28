import 'dart:async';
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

/// Runs [op] and returns the runtime type name of the error it completes with,
/// or `'ok'` if it completed normally. The error handler is attached to the
/// future via `.then(onError:)` (synchronously chained) rather than
/// `await`-in-try/catch: the latter makes flutter_test's zone double-report the
/// `.timeout()` throw as an unhandled error. This mirrors how the real
/// AuthInterceptor consumes refreshIfNeeded (its failure is caught, not left to
/// bubble).
Future<String> _outcome(Future<void> Function() op) =>
    op().then((_) => 'ok', onError: (Object e) => e.runtimeType.toString());

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

    test(
        'wedged refresh times out and CLEARS the slot so the next call re-enters',
        () async {
      // THE BUG (Gap A): on Flutter web, if a refresh is in-flight when the
      // browser suspends a backgrounded tab, the socket can die WITHOUT the
      // Future ever completing. Before this fix _inflight never cleared, so on
      // resume every request's onRequest awaited the wedged future forever →
      // the whole app spun until a full page reload. The timeout must clear the
      // slot so a subsequent call re-enters instead of returning the stuck one.
      int calls = 0;
      final expiring = _buildJwt(exp: _expAt(const Duration(seconds: 10)));
      final pr = ProactiveRefresh(
        getAccessToken: () => expiring,
        // A fresh never-completing future each call — simulates a refresh whose
        // socket died at tab-suspend (the Future never resolves or errors).
        restoreSession: () {
          calls++;
          return Completer<void>().future;
        },
        refreshTimeout: const Duration(milliseconds: 50),
      );

      expect(await _outcome(pr.refreshIfNeeded), 'TimeoutException',
          reason: 'a refresh that never completes must time out, not hang');
      expect(calls, 1);

      // The wedged future must NOT poison later calls: the slot cleared, so a
      // fresh call calls restoreSession AGAIN rather than handing back the
      // stuck future. This is the app-wide-spinner fix.
      expect(await _outcome(pr.refreshIfNeeded), 'TimeoutException');
      expect(calls, 2,
          reason: 'slot cleared on timeout → next call re-enters');
    });

    test('concurrent callers on a wedged refresh all time out (no infinite hang)',
        () async {
      final wedged = Completer<void>();
      final expiring = _buildJwt(exp: _expAt(const Duration(seconds: 10)));
      final pr = ProactiveRefresh(
        getAccessToken: () => expiring,
        restoreSession: () => wedged.future,
        refreshTimeout: const Duration(milliseconds: 50),
      );

      final outcomes = await Future.wait<String>([
        pr.refreshIfNeeded().then((_) => 'ok').catchError((Object e) => 'to'),
        pr.refreshIfNeeded().then((_) => 'ok').catchError((Object e) => 'to'),
        pr.refreshIfNeeded().then((_) => 'ok').catchError((Object e) => 'to'),
      ]);

      expect(outcomes, everyElement('to'),
          reason: 'no concurrent caller may hang past the refresh timeout');
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
