import 'dart:async';

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingNotifier extends MutationNotifier<int> {
  int builds = 0;

  @override
  MutationState<int> build() {
    builds++;
    return super.build();
  }
}

final _saveProvider = NotifierProvider<MutationNotifier<int>, MutationState<int>>(
  MutationNotifier<int>.new,
);

final _autoDisposeProvider = AutoDisposeNotifierProvider<
    AutoDisposeMutationNotifier<int>, MutationState<int>>(
  AutoDisposeMutationNotifier<int>.new,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('starts in idle', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(_saveProvider).isIdle, true);
  });

  test('run flips to inFlight then success', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final completer = Completer<int>();
    final future = container.read(_saveProvider.notifier).run(() => completer.future);

    // After scheduling, state should be inFlight
    expect(container.read(_saveProvider).isInFlight, true);

    completer.complete(42);
    final result = await future;
    expect(result, 42);
    expect(container.read(_saveProvider).isSuccess, true);
    final state = container.read(_saveProvider) as MutationSuccess<int>;
    expect(state.result, 42);
  });

  test('run captures failure and stores error+stack', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final result = await container
        .read(_saveProvider.notifier)
        .run(() async => throw StateError('boom'));

    expect(result, isNull);
    expect(container.read(_saveProvider).isFailure, true);
    final state = container.read(_saveProvider) as MutationFailure<int>;
    expect(state.error, isA<StateError>());
    expect(state.stackTrace, isNotNull);
  });

  test('reset returns to idle', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container
        .read(_saveProvider.notifier)
        .run(() async => throw StateError('boom'));
    expect(container.read(_saveProvider).isFailure, true);

    container.read(_saveProvider.notifier).reset();
    expect(container.read(_saveProvider).isIdle, true);
  });

  test('concurrent run is dropped while in flight', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final c1 = Completer<int>();
    final f1 = container.read(_saveProvider.notifier).run(() => c1.future);
    expect(container.read(_saveProvider).isInFlight, true);

    // Second run while first is in flight should drop and return null
    final f2 = container
        .read(_saveProvider.notifier)
        .run(() async => 999);

    expect(await f2, isNull);

    c1.complete(7);
    expect(await f1, 7);
  });

  test('when() dispatches by state', () {
    expect(
      const MutationState<int>.idle().when(
        idle: () => 'i',
        inFlight: () => 'p',
        success: (_) => 's',
        failure: (_, __) => 'f',
      ),
      'i',
    );
    expect(
      const MutationState<int>.inFlight().when(
        idle: () => 'i',
        inFlight: () => 'p',
        success: (_) => 's',
        failure: (_, __) => 'f',
      ),
      'p',
    );
    expect(
      const MutationState<int>.success(5).when(
        idle: () => 'i',
        inFlight: () => 'p',
        success: (v) => 's:$v',
        failure: (_, __) => 'f',
      ),
      's:5',
    );
    expect(
      MutationState<int>.failure(StateError('x'), StackTrace.empty).when(
        idle: () => 'i',
        inFlight: () => 'p',
        success: (_) => 's',
        failure: (e, _) => 'f:${e.toString()}',
      ),
      contains('f:Bad state: x'),
    );
  });

  test('AutoDisposeMutationNotifier behaves like keep-alive variant',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final sub = container.listen(_autoDisposeProvider, (_, __) {});
    expect(container.read(_autoDisposeProvider).isIdle, true);

    final result =
        await container.read(_autoDisposeProvider.notifier).run(() async => 11);
    expect(result, 11);
    expect(container.read(_autoDisposeProvider).isSuccess, true);

    container.read(_autoDisposeProvider.notifier).reset();
    expect(container.read(_autoDisposeProvider).isIdle, true);
    sub.close();
  });

  test('subclass run preserves return value', () async {
    final provider = NotifierProvider<_CountingNotifier, MutationState<int>>(
      _CountingNotifier.new,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final result =
        await container.read(provider.notifier).run(() async => 99);
    expect(result, 99);
    expect(container.read(provider).isSuccess, true);
    expect(container.read(provider.notifier).builds, 1);
  });
}
