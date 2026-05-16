import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:eden_ui_flutter/eden_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('edenSnapshotFromAsyncValue', () {
    test('AsyncValue.data maps to EdenAsyncSnapshot.data', () {
      const value = AsyncValue.data(42);
      final snapshot = edenSnapshotFromAsyncValue(value);
      expect(snapshot, isA<EdenAsyncData<int>>());
      expect(snapshot.value, 42);
    });

    test('AsyncValue.loading maps to EdenAsyncSnapshot.loading', () {
      const value = AsyncValue<int>.loading();
      final snapshot = edenSnapshotFromAsyncValue(value);
      expect(snapshot, isA<EdenAsyncLoading<int>>());
      expect(snapshot.value, isNull);
    });

    test('AsyncValue.error maps to EdenAsyncSnapshot.error', () {
      final err = Exception('boom');
      final st = StackTrace.current;
      final value = AsyncValue<int>.error(err, st);
      final snapshot = edenSnapshotFromAsyncValue(value);
      expect(snapshot, isA<EdenAsyncError<int>>());
      expect(snapshot.value, isNull);
      // Verify the error and stack trace are preserved.
      final asError = snapshot as EdenAsyncError<int>;
      expect(asError.error, err);
      expect(asError.stackTrace, st);
    });

    test('when() delegate works correctly after conversion', () {
      const value = AsyncValue.data('hello');
      final snapshot = edenSnapshotFromAsyncValue(value);
      final result = snapshot.when(
        data: (d) => 'got: $d',
        loading: () => 'loading',
        error: (e, _) => 'error',
      );
      expect(result, 'got: hello');
    });

    test('works with nullable inner type', () {
      const value = AsyncValue<String?>.data(null);
      final snapshot = edenSnapshotFromAsyncValue(value);
      expect(snapshot, isA<EdenAsyncData<String?>>());
      // value is null — EdenAsyncData.value returns the data as-is.
      expect((snapshot as EdenAsyncData<String?>).data, isNull);
    });
  });
}
