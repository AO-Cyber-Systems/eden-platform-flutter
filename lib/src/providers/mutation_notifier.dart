import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Lifecycle of a single CRUD-style mutation tracked by [MutationNotifier].
@immutable
sealed class MutationState<T> {
  const MutationState();

  const factory MutationState.idle() = MutationIdle<T>;
  const factory MutationState.inFlight() = MutationInFlight<T>;
  const factory MutationState.success(T result) = MutationSuccess<T>;
  const factory MutationState.failure(Object error, StackTrace stackTrace) =
      MutationFailure<T>;

  bool get isIdle => this is MutationIdle<T>;
  bool get isInFlight => this is MutationInFlight<T>;
  bool get isSuccess => this is MutationSuccess<T>;
  bool get isFailure => this is MutationFailure<T>;

  /// Reduce-style branching helper.
  R when<R>({
    required R Function() idle,
    required R Function() inFlight,
    required R Function(T result) success,
    required R Function(Object error, StackTrace stack) failure,
  }) {
    final self = this;
    if (self is MutationIdle<T>) return idle();
    if (self is MutationInFlight<T>) return inFlight();
    if (self is MutationSuccess<T>) return success(self.result);
    if (self is MutationFailure<T>) return failure(self.error, self.stackTrace);
    throw StateError('Unreachable: unknown MutationState subtype');
  }
}

class MutationIdle<T> extends MutationState<T> {
  const MutationIdle();
}

class MutationInFlight<T> extends MutationState<T> {
  const MutationInFlight();
}

class MutationSuccess<T> extends MutationState<T> {
  const MutationSuccess(this.result);
  final T result;
}

class MutationFailure<T> extends MutationState<T> {
  const MutationFailure(this.error, this.stackTrace);
  final Object error;
  final StackTrace stackTrace;
}

/// Generic Riverpod notifier for tracking the lifecycle of a single
/// CRUD-style mutation (create, update, delete, etc.).
///
/// ## What it pins down
///
/// CRUD screens repeatedly hand-roll the same fields:
///
/// ```
/// bool _saving = false;
/// String? _error;
/// Future<void> _save() async { setState(() { _saving = true; _error = null; });
///   try { await repo.save(...);... } catch (e) { setState(() { _error = '$e'; }); }
///   finally { setState(() { _saving = false; }); } }
/// ```
///
/// Every form gets it slightly wrong — duplicate submits, stale error after
/// a retry, success state never reset. `MutationNotifier<T>` owns the state
/// machine.
///
/// ## Subclass-free usage
///
/// Most callers don't need a subclass — they just create a one-off provider:
///
/// ```dart
/// final saveConversationMutation = NotifierProvider<
///     MutationNotifier<Conversation>, MutationState<Conversation>>(
///   MutationNotifier<Conversation>.new,
///   isAutoDispose: true, // drop the state when the last listener detaches
/// );
///
/// // In the widget:
/// final state = ref.watch(saveConversationMutation);
/// final notifier = ref.read(saveConversationMutation.notifier);
///
/// EdenButton(
///   label: state.isInFlight ? 'Saving…': 'Save',
///   onPressed: state.isInFlight ? null: () async {
///     await notifier.run(() => repo.update(id, title));
///   },
/// );
/// ```
///
/// ## Subclass usage (for shared mutations)
///
/// When the mutation logic is reused, subclass and expose typed methods:
///
/// ```dart
/// final renameConversationMutation = NotifierProvider<
///     RenameConversationNotifier, MutationState<void>>(
///   RenameConversationNotifier.new,
/// );
///
/// class RenameConversationNotifier extends MutationNotifier<void> {
///   Future<void> rename(String id, String title) =>
///       run(() async {
///         final repo = ref.read(conversationRepositoryProvider);
///         await repo.update(id, title: title);
///       });
/// }
/// ```
///
/// ## Choosing the lifetime (there is only ONE notifier class)
///
/// There is no separate auto-dispose notifier class. Lifetime is a property of
/// the **provider**:
///
/// ```dart
/// // keep-alive: state survives the last listener detaching
/// NotifierProvider<MutationNotifier<T>, MutationState<T>>(
///   MutationNotifier<T>.new,
/// );
///
/// // auto-dispose: state is dropped when the last listener detaches
/// NotifierProvider<MutationNotifier<T>, MutationState<T>>(
///   MutationNotifier<T>.new,
///   isAutoDispose: true,
/// );
/// ```
///
/// `NotifierProvider.autoDispose<...>(...)` is equivalent sugar for the second
/// form. Both are covered by `test/providers/mutation_notifier_test.dart`,
/// which proves the drop-on-detach behaviour against a keep-alive control.
///
/// This package previously shipped a second class,
/// `AutoDisposeMutationNotifier<T>`, whose superclass riverpod 3 deleted. It is
/// **gone**; migrate to the provider flag above. See
/// `doc/riverpod-3-migration.md` §3.1.
class MutationNotifier<T> extends Notifier<MutationState<T>> {
  @override
  MutationState<T> build() => MutationState<T>.idle();

  /// Execute the mutation. Sets state to inFlight, then success or failure.
  ///
  /// Concurrent calls are coalesced — if a mutation is already in flight,
  /// subsequent [run] calls before completion are dropped (return value is
  /// the last successful or failing future result; new calls return null
  /// during in-flight). Override [allowConcurrent] to true to opt in.
  ///
  /// ## Notification semantics (riverpod 3 filters every update with `==`)
  ///
  /// [MutationState] deliberately does NOT override `==`, so `==` is identity.
  /// Combined with riverpod 3's update filtering that makes the const and
  /// non-const constructors behave differently, which is measured and pinned by
  /// `test/providers/mutation_notifier_test.dart`:
  ///
  /// - `const MutationState.inFlight()` is **const-canonicalized** — every
  ///   evaluation yields the identical instance. Assigning it while already
  ///   inFlight notifies listeners **zero** extra times.
  /// - `MutationState<T>.idle()` in [reset] is **not** const and allocates a
  ///   fresh instance, so calling [reset] twice notifies **twice**.
  ///
  /// Both are intentional. Value equality is NOT added to [MutationState]: it
  /// would also collapse a genuine re-`run` that produced an equal result, and
  /// UIs legitimately re-trigger on a repeated success.
  Future<T?> run(Future<T> Function() task) async {
    if (state.isInFlight && !allowConcurrent) {
      return null;
    }
    // const: canonicalized, so a redundant inFlight->inFlight write is filtered
    // by riverpod 3's `==` check rather than waking every listener.
    state = const MutationState.inFlight();
    try {
      final result = await task();
      state = MutationState.success(result);
      return result;
    } catch (e, st) {
      state = MutationState.failure(e, st);
      return null;
    }
  }

  /// Reset to idle. Useful after the UI has surfaced a success/failure.
  ///
  /// Note the missing `const`: this allocates a fresh [MutationIdle] every
  /// call, so `reset()` always notifies — including when already idle. See the
  /// notification-semantics section on [run].
  void reset() {
    state = MutationState<T>.idle();
  }

  /// Whether [run] should accept concurrent invocations. Defaults to false
  /// (re-entrant calls are dropped). Override to true if your mutation is
  /// safe to dispatch concurrently and you want each call to update state.
  @protected
  bool get allowConcurrent => false;
}

// `AutoDisposeMutationNotifier<T>` used to live here. It was a verbatim
// duplicate of [MutationNotifier]'s body whose only distinguishing feature was
// its superclass, and riverpod 3 deleted that superclass (it fused the
// auto-dispose notifier base class into the plain one). Auto-dispose is now
// expressed on the PROVIDER — `NotifierProvider(..., isAutoDispose: true)` —
// so one notifier class covers both lifetimes and the duplicate has no reason
// to exist.
//
// Deliberately NOT replaced with a typedef or subclass alias: a local alias
// would hide a real upstream break from every consumer and guarantee a second
// migration later. The removal, the replacement recipe and the consumer impact
// are recorded in doc/riverpod-3-migration.md §3.1.
