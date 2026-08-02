import 'dart:async';
import 'dart:io';

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

/// Opts in to concurrent runs so the SECOND `run()` actually reaches the
/// inFlight assignment (the default guard returns before it).
class _ConcurrentNotifier extends MutationNotifier<int> {
  @override
  bool get allowConcurrent => true;
}

final _saveProvider = NotifierProvider<MutationNotifier<int>, MutationState<int>>(
  MutationNotifier<int>.new,
);

// Auto-dispose is a PROVIDER flag in riverpod 3, not a notifier base class.
// Verified against the resolved riverpod 3.3.2:
//   riverpod-3.3.2/lib/src/providers/notifier/orphan.dart:86
//     NotifierProvider(this._createNotifier, {..., super.isAutoDispose = false, ...})
// `NotifierProvider.autoDispose<...>` (orphan.dart:108) is equivalent sugar.
// Both spellings are exercised below so neither can rot unnoticed.
final _autoDisposeProvider =
    NotifierProvider<MutationNotifier<int>, MutationState<int>>(
  MutationNotifier<int>.new,
  isAutoDispose: true,
);

// Same notifier class, sugar spelling — proves the two forms agree.
final _autoDisposeSugarProvider = NotifierProvider.autoDispose<
    MutationNotifier<int>, MutationState<int>>(
  MutationNotifier<int>.new,
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

  // ---------------------------------------------------------------------
  // riverpod 3 semantics. The mechanism for auto-dispose MOVED (notifier base
  // class -> provider flag), so "it still works" is demonstrated, not assumed.
  //
  // NOTE ON SUBSCRIBING: `container.read(p)` does NOT subscribe under riverpod
  // 3 — it opens a subscription and closes it immediately, which for an
  // auto-dispose provider is itself a detach. Every test below subscribes with
  // `container.listen(...)` and detaches by calling `sub.close()`.
  // ---------------------------------------------------------------------

  test('auto-dispose provider DROPS state when the last listener detaches',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final sub = container.listen(_autoDisposeProvider, (previous, next) {});
    final result =
        await container.read(_autoDisposeProvider.notifier).run(() async => 11);
    expect(result, 11);
    expect(container.read(_autoDisposeProvider).isSuccess, true,
        reason: 'sanity: the mutation did land while listened');

    sub.close();
    await Future<void>.delayed(Duration.zero);

    expect(container.read(_autoDisposeProvider).isIdle, true,
        reason: 'auto-dispose must drop the success state on last detach');
    expect(container.read(_autoDisposeProvider).isSuccess, false);
  });

  test(
      'CONTROL: keep-alive provider RETAINS state across the same detach '
      '(so the test above measures the flag, not the default)', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final sub = container.listen(_saveProvider, (previous, next) {});
    final result =
        await container.read(_saveProvider.notifier).run(() async => 11);
    expect(result, 11);
    expect(container.read(_saveProvider).isSuccess, true);

    sub.close();
    await Future<void>.delayed(Duration.zero);

    expect(container.read(_saveProvider).isSuccess, true,
        reason: 'keep-alive must survive the identical detach sequence');
    expect(container.read(_saveProvider).isIdle, false);
  });

  test('NotifierProvider.autoDispose sugar agrees with isAutoDispose: true',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final sub = container.listen(_autoDisposeSugarProvider, (previous, next) {});
    await container.read(_autoDisposeSugarProvider.notifier).run(() async => 5);
    expect(container.read(_autoDisposeSugarProvider).isSuccess, true);

    sub.close();
    await Future<void>.delayed(Duration.zero);

    expect(container.read(_autoDisposeSugarProvider).isIdle, true);
  });

  test('auto-dispose notifier is REBUILT after a drop, not resumed', () async {
    final p = NotifierProvider<_CountingNotifier, MutationState<int>>(
      _CountingNotifier.new,
      isAutoDispose: true,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final sub1 = container.listen(p, (previous, next) {});
    expect(container.read(p.notifier).builds, 1);
    sub1.close();
    await Future<void>.delayed(Duration.zero);

    final sub2 = container.listen(p, (previous, next) {});
    expect(container.read(p.notifier).builds, 1,
        reason: 'a fresh notifier instance whose build() ran exactly once — '
            'not the old instance with builds==2');
    expect(container.read(p).isIdle, true);
    sub2.close();
  });

  test(
      'const-canonicalized inFlight notifies ONCE; non-const reset() notifies '
      'every call', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var notifications = 0;
    container.listen(_saveProvider, (previous, next) => notifications++);
    final n = container.read(_saveProvider.notifier);

    // Guard the premise this whole test rests on.
    expect(
      identical(const MutationState<int>.inFlight(),
          const MutationState<int>.inFlight()),
      true,
      reason: 'const constructors are canonicalized to one instance',
    );
    expect(
      identical(MutationState<int>.idle(), MutationState<int>.idle()),
      false,
      reason: 'the non-const factory allocates fresh every call',
    );

    n.state = const MutationState.inFlight();
    expect(notifications, 1, reason: 'idle -> inFlight is a real change');

    n.state = const MutationState.inFlight();
    expect(notifications, 1,
        reason: 'riverpod 3 filters updates with `==`; the const sentinel is '
            'the IDENTICAL instance, so the second write does not notify');

    n.reset();
    expect(notifications, 2, reason: 'inFlight -> idle is a real change');

    n.reset();
    expect(notifications, 3,
        reason: 'reset() uses a NON-const idle(), allocating a fresh instance, '
            'so an idle -> idle write DOES notify. Two nearly identical lines '
            'with different notification behaviour — this is the trap.');

    n.state = const MutationState.idle();
    expect(notifications, 4, reason: 'fresh idle -> const idle differs by identity');

    n.state = const MutationState.idle();
    expect(notifications, 4,
        reason: 'const idle is canonicalized too — filtered, like inFlight');
  });

  test(
      'run() itself relies on the const sentinel: a concurrent re-run does not '
      're-notify', () async {
    // Added after mutation testing: the notification test above assigns `state`
    // directly, so dropping `const` from run()'s own inFlight assignment
    // SURVIVED it. This drives the production method instead. It needs
    // allowConcurrent:true, because the default guard returns before the second
    // assignment is ever reached.
    final p = NotifierProvider<_ConcurrentNotifier, MutationState<int>>(
      _ConcurrentNotifier.new,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var notifications = 0;
    container.listen(p, (previous, next) => notifications++);
    final n = container.read(p.notifier);

    final c1 = Completer<int>();
    final c2 = Completer<int>();
    final f1 = n.run(() => c1.future);
    expect(notifications, 1, reason: 'idle -> inFlight');

    final f2 = n.run(() => c2.future);
    expect(notifications, 1,
        reason: 'a second concurrent run assigns the SAME canonical const '
            'inFlight instance, so riverpod 3 filters it. Drop the `const` in '
            'run() and this becomes 2 — a wasted rebuild of every listener.');

    c1.complete(1);
    c2.complete(2);
    await f1;
    await f2;
    expect(notifications, 3, reason: 'two distinct success values do notify');
  });

  // ---------------------------------------------------------------------
  // Source-level assertion: the removed symbol is GONE, not shimmed.
  //
  // Scoped deliberately. A bare whole-repo grep cannot tell a DECLARATION from
  // a passing mention in prose, so this walks the sources and classifies each
  // hit: declarations (class/typedef/extends) are failures, and the deleted
  // riverpod base-class name is banned outright from lib/ + test/ so a stale
  // copy-paste recipe cannot survive in a doc comment.
  // ---------------------------------------------------------------------
  group('riverpod-3 removal is real, not shimmed', () {
    List<File> dartAndMarkdownSources() {
      final roots = [Directory('lib'), Directory('test')];
      return roots
          .expand((d) => d.listSync(recursive: true))
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart') || f.path.endsWith('.md'))
          .toList();
    }

    test('fixture guard: the source walker actually finds files', () {
      final files = dartAndMarkdownSources();
      expect(files.length, greaterThan(20),
          reason: 'a walker that finds nothing would make every assertion '
              'below pass vacuously');
      expect(
        files.map((f) => f.path),
        contains(endsWith('lib/src/providers/mutation_notifier.dart')),
      );
      expect(
        files.map((f) => f.path),
        contains(endsWith('lib/src/providers/README.md')),
      );
    });

    test('no declaration of the deleted AutoDisposeMutationNotifier survives',
        () {
      final decl = RegExp(
        r'(^|\s)(abstract\s+)?(class|typedef)\s+AutoDisposeMutationNotifier\b',
        multiLine: true,
      );
      final offenders = <String>[];
      for (final f in dartAndMarkdownSources()) {
        if (decl.hasMatch(f.readAsStringSync())) offenders.add(f.path);
      }
      expect(offenders, isEmpty,
          reason: 'the class must be deleted, not re-introduced as an alias');
    });

    // The banned identifier is ASSEMBLED at runtime rather than written as a
    // literal. Spelling it out would make this file match its own rule, which
    // would force a self-exclusion — and a gate with a carve-out for the one
    // file most likely to contain a stale recipe is a weak gate. Built this
    // way, the walk covers every file including this one, with no exemptions.
    final bannedSymbol = ['AutoDispose', 'Notifier'].join();

    test('the deleted riverpod base-class symbol appears nowhere in lib/ or test/',
        () {
      // Matches the deleted riverpod class and its *Provider form, but NOT
      // eden's own AutoDisposeMutationNotifier (a different literal).
      final offenders = <String>[];
      for (final f in dartAndMarkdownSources()) {
        for (final line in f.readAsStringSync().split('\n')) {
          if (line.contains(bannedSymbol)) offenders.add('${f.path}: $line');
        }
      }
      expect(offenders, isEmpty,
          reason: 'riverpod 3 deleted $bannedSymbol. Recipes naming it teach a '
              'break downstream. The migration story belongs in '
              'doc/riverpod-3-migration.md, which is outside lib/ and test/ '
              'and so is deliberately not covered by this walk.');
    });

    test('the ban is discriminating, not vacuously empty', () {
      // Nil-only fixtures hide broken predicates: prove the same walk+predicate
      // DOES flag a planted offender before trusting its silence above.
      final planted = 'final p = ${bannedSymbol}Provider<Foo, Bar>(Foo.new);';
      expect(planted.contains(bannedSymbol), isTrue);
      // and prove it does NOT flag eden's own (different) class name
      expect('class AutoDisposeMutationNotifier<T> {}'.contains(bannedSymbol),
          isFalse,
          reason: 'the two names differ; a sloppier predicate would conflate '
              'them and this gate would fire on the wrong thing');
    });

    test('mutation_notifier.dart declares exactly one Notifier subclass', () {
      final src =
          File('lib/src/providers/mutation_notifier.dart').readAsStringSync();
      final classes = RegExp(
              r'^class\s+(\w+)(?:<[^>]*>)?\s+extends\s+Notifier<',
              multiLine: true)
          .allMatches(src)
          .map((m) => m.group(1))
          .toList();
      expect(classes, ['MutationNotifier'],
          reason: 'scoped to this file and to the Notifier supertype — a '
              'whole-repo grep could not tell which declaration it matched');
    });
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
