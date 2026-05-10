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
///   try { await repo.save(...); ... } catch (e) { setState(() { _error = '$e'; }); }
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
/// final saveConversationMutation = AutoDisposeNotifierProvider<
///     MutationNotifier<Conversation>, MutationState<Conversation>>(
///   MutationNotifier<Conversation>.new,
/// );
///
/// // In the widget:
/// final state = ref.watch(saveConversationMutation);
/// final notifier = ref.read(saveConversationMutation.notifier);
///
/// EdenButton(
///   label: state.isInFlight ? 'Saving…' : 'Save',
///   onPressed: state.isInFlight ? null : () async {
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
class MutationNotifier<T> extends Notifier<MutationState<T>> {
  @override
  MutationState<T> build() => MutationState<T>.idle();

  /// Execute the mutation. Sets state to inFlight, then success or failure.
  ///
  /// Concurrent calls are coalesced — if a mutation is already in flight,
  /// subsequent [run] calls before completion are dropped (return value is
  /// the last successful or failing future result; new calls return null
  /// during in-flight). Override [allowConcurrent] to true to opt in.
  Future<T?> run(Future<T> Function() task) async {
    if (state.isInFlight && !allowConcurrent) {
      return null;
    }
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
  void reset() {
    state = MutationState<T>.idle();
  }

  /// Whether [run] should accept concurrent invocations. Defaults to false
  /// (re-entrant calls are dropped). Override to true if your mutation is
  /// safe to dispatch concurrently and you want each call to update state.
  @protected
  bool get allowConcurrent => false;
}

/// AutoDispose variant — drops state when the last listener detaches.
/// Use for one-off form-submit mutations.
class AutoDisposeMutationNotifier<T>
    extends AutoDisposeNotifier<MutationState<T>> {
  @override
  MutationState<T> build() => MutationState<T>.idle();

  Future<T?> run(Future<T> Function() task) async {
    if (state.isInFlight && !allowConcurrent) {
      return null;
    }
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

  void reset() {
    state = MutationState<T>.idle();
  }

  @protected
  bool get allowConcurrent => false;
}
