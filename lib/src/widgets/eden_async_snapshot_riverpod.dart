import 'package:eden_ui_flutter/eden_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Converts a Riverpod [AsyncValue] to an [EdenAsyncSnapshot].
///
/// This adapter lets Riverpod-backed providers drive [EdenAsyncFormScaffold]
/// without taking a direct riverpod dependency inside `eden_ui_flutter`.
///
/// Example:
/// ```dart
/// ref.watch(invoiceProvider).when(
///   data: (invoice) => EdenAsyncFormScaffold(
///     snapshot: edenSnapshotFromAsyncValue(ref.watch(invoiceProvider)),
///     ...
///   ),
///   ...
/// );
///
/// // Or, more concisely:
/// EdenAsyncFormScaffold(
///   snapshot: edenSnapshotFromAsyncValue(ref.watch(invoiceProvider)),
///   ...
/// )
/// ```
EdenAsyncSnapshot<T> edenSnapshotFromAsyncValue<T>(AsyncValue<T> value) {
  return value.when(
    data: EdenAsyncSnapshot.data,
    error: EdenAsyncSnapshot.error,
    loading: EdenAsyncSnapshot.loading,
  );
}
