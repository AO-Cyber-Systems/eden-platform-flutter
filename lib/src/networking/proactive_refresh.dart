import 'dart:async';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter/foundation.dart';

/// Proactive JWT token refresh with single-flight protection.
///
/// **What:** Refreshes the access token BEFORE it expires:
/// - Pre-flight check in an auth interceptor's `onRequest`: if less than
///   [threshold] is remaining, await refresh before sending the request.
/// - `AppLifecycleListener.onResume` hook: if less than [threshold] is
///   remaining when the app returns from background, fire a refresh.
///
/// **Single-flight:** concurrent triggers (proactive timer + reactive
/// 401 interceptor + resume listener) collapse to one in-flight refresh via
/// `Completer<void>?`. All concurrent callers attach to the same [Future].
///
/// **No-op cases (does NOT throw upstream):**
/// - null access token (no auth state to refresh)
/// - malformed JWT (decode fails — let the reactive 401 path catch failures)
/// - JWT without `exp` claim
/// - `exp` more than [threshold] away (still fresh)
///
/// **Architecture:** accepts callbacks for testability. Wire in your Riverpod
/// provider or DI framework:
/// ```dart
/// ProactiveRefresh(
///   getAccessToken: () => ref.read(authProvider).accessToken,
///   restoreSession: () => ref.read(authProvider.notifier).restoreSession(),
/// )
/// ```
class ProactiveRefresh {
  ProactiveRefresh({
    required this.getAccessToken,
    required this.restoreSession,
    this.threshold = const Duration(minutes: 2),
  });

  /// Returns the current access token, or null if unauthenticated.
  final String? Function() getAccessToken;

  /// Refresh primitive — typically the auth provider's `restoreSession` or
  /// equivalent token-rotation method.
  final Future<void> Function() restoreSession;

  /// How much remaining lifetime triggers a proactive refresh. Default: 2m.
  final Duration threshold;

  Future<void>? _inflight;

  /// Refresh the access token if it has less than [threshold] remaining.
  ///
  /// Concurrent callers collapse to a single refresh by attaching to the
  /// in-flight [Future]. Failure propagates to the caller; the in-flight slot
  /// is cleared in `whenComplete` so subsequent callers can retry.
  Future<void> refreshIfNeeded() {
    final inflight = _inflight;
    if (inflight != null) {
      return inflight;
    }
    final token = getAccessToken();
    if (token == null) return Future<void>.value();
    final exp = _decodeExp(token);
    if (exp == null) return Future<void>.value();
    final remaining = exp.difference(DateTime.now().toUtc());
    if (remaining > threshold) return Future<void>.value();

    // Single-flight: wrap the refresh in a stored Future. Concurrent callers
    // attach to the same Future. Once it resolves (or fails), clear the slot
    // so the next call re-enters.
    final f = restoreSession().whenComplete(() {
      _inflight = null;
    });
    _inflight = f;
    return f;
  }

  static DateTime? _decodeExp(String jwt) {
    try {
      final decoded = JWT.decode(jwt);
      final payload = decoded.payload;
      if (payload is Map<String, dynamic>) {
        final exp = payload['exp'];
        if (exp is int) {
          return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
        }
      }
    } catch (_) {
      // Malformed JWT — treat as no-op. The reactive 401 path is the
      // source of truth for refresh decisions; proactive refresh is a hint.
    }
    return null;
  }
}

/// Wraps [ProactiveRefresh.refreshIfNeeded] for fire-and-forget invocation
/// from `AppLifecycleListener.onResume`.
///
/// Errors from [ProactiveRefresh.restoreSession] are caught and logged in
/// debug mode but not rethrown. The reactive 401 path handles definite
/// refresh failures.
void onAppResumeCallProactiveRefresh(ProactiveRefresh pr) {
  unawaited(pr.refreshIfNeeded().catchError((Object e, StackTrace st) {
    if (kDebugMode) {
      debugPrint('proactive refresh on resume failed: $e');
    }
  }));
}
