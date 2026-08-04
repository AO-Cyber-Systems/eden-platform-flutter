// THE ONE SLOT EVERY REFRESH-TOKEN ROTATION PASSES THROUGH.
//
// Riverpod-free and Flutter-free — it imports nothing at all.
//
// ## Why this is a separate type rather than a copy of ProactiveRefresh's
//
// `ProactiveRefresh` (lib/src/networking/proactive_refresh.dart:56-90) already
// collapses concurrent refreshes onto one `Future`, and a tenant switch IS a
// refresh with an extra parameter. If the switch had its own slot, the two
// would not collapse AGAINST EACH OTHER: a switch and a proactive refresh
// would fire together, each rotating the refresh token, and one would rotate
// it out from under the other. The user is signed out. Two independent
// single-flight slots are not single-flight.
//
// So there is ONE implementation and two callers, wired through
// `ProactiveRefresh`'s existing injection seam:
//
// ```dart
// final controller = AoidTenantController(...);
// ProactiveRefresh(
//   getAccessToken: () => ref.read(authProvider).accessToken,
//   restoreSession: controller.refreshSession,   // <- lands in THIS slot
// );
// ```
//
// `ProactiveRefresh` is deliberately NOT edited to reach in here. Its
// `restoreSession` callback is already the composition point, so routing
// through it needs no change to a file three other TRDs are touching in
// parallel, and it keeps this primitive dependency-free.
//
// ## Two entry points, because a switch and a refresh want different things
//
// They are NOT symmetric, and collapsing them would be a silent bug:
//
// * A refresh only wants the token to be fresh. If a rotation is already in
//   flight — even a SWITCH — waiting for it satisfies the refresh completely.
//   That is [join], and it is what makes the concurrent case ONE network call.
//
// * A switch wants a SPECIFIC tenant. Attaching it to someone else's rotation
//   would return "success" while the active tenant never changed — the client
//   would believe it is in tenant B while its token says A, which is precisely
//   the cross-tenant residue this module exists to prevent. So a switch takes
//   the slot EXCLUSIVELY, queueing behind anything in flight. Two SEQUENTIAL
//   rotations are safe; it is two CONCURRENT ones that sign the user out.

import 'dart:async';

/// Serialises refresh-token rotations so two can never overlap.
class AoidRefreshSingleFlight {
  Future<void>? _inflight;

  /// Whether a rotation is currently in flight.
  bool get isBusy => _inflight != null;

  /// Occupy the slot EXCLUSIVELY, waiting for anything already in flight.
  ///
  /// Use for an operation whose effect is specific — a tenant switch — where
  /// attaching to someone else's rotation would silently not do the thing that
  /// was asked for.
  ///
  /// A preceding operation's FAILURE does not propagate here: this caller gets
  /// its own attempt either way.
  Future<T> runExclusive<T>(Future<T> Function() operation) async {
    // The body up to the first `await` runs synchronously, so two callers in
    // the same microtask cannot both observe a free slot.
    while (_inflight != null) {
      try {
        await _inflight;
      } catch (_) {
        // Someone else's failure is not this caller's problem.
      }
    }

    final occupied = Completer<void>();
    _inflight = occupied.future;
    try {
      return await operation();
    } finally {
      _inflight = null;
      occupied.complete();
    }
  }

  /// Attach to the rotation already in flight, or start [operation].
  ///
  /// Use for an operation that only wants the token to be FRESH — a proactive
  /// or reactive refresh. When a switch is already running, this returns when
  /// that switch completes and no second request is made.
  ///
  /// If the in-flight rotation FAILS, this does not inherit the failure: the
  /// token was not refreshed, so [operation] runs on its own.
  Future<void> join(Future<void> Function() operation) async {
    final inflight = _inflight;
    if (inflight != null) {
      try {
        await inflight;
        return;
      } catch (_) {
        // It did not rotate anything. Fall through and do our own.
      }
    }
    return runExclusive(operation);
  }
}
