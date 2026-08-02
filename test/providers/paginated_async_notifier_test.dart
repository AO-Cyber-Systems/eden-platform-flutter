import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Item {
  const _Item(this.id, this.title, {this.pinned = false});
  final String id;
  final String title;
  final bool pinned;

  _Item copyWith({String? title, bool? pinned}) =>
      _Item(id, title ?? this.title, pinned: pinned ?? this.pinned);

  @override
  String toString() => '_Item($id, $title, pinned=$pinned)';
}

/// A test notifier that returns canned pages from a stub closure.
class _TestNotifier extends PaginatedAsyncNotifier<_Item> {
  _TestNotifier(this._fetcher, {this.sortByTitle = false});
  final Future<PaginatedPage<_Item>> Function(String? cursor) _fetcher;
  final bool sortByTitle;

  @override
  Future<PaginatedPage<_Item>> fetchPage(String? cursor) => _fetcher(cursor);

  @override
  void sortItems(List<_Item> items) {
    if (sortByTitle) {
      items.sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return a.title.compareTo(b.title);
      });
    }
  }
}

AsyncNotifierProvider<_TestNotifier, List<_Item>> _provider(
  Future<PaginatedPage<_Item>> Function(String? cursor) fetcher, {
  bool sortByTitle = false,
}) =>
    AsyncNotifierProvider<_TestNotifier, List<_Item>>(
      () => _TestNotifier(fetcher, sortByTitle: sortByTitle),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('build fetches the first page and tracks hasMore', () async {
    final p = _provider((cursor) async {
      expect(cursor, isNull);
      return const PaginatedPage(
        items: [_Item('a', 'A'), _Item('b', 'B')],
        hasMore: true,
        nextCursor: 'c2',
      );
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final items = await container.read(p.future);
    expect(items.map((i) => i.id), ['a', 'b']);
    final notifier = container.read(p.notifier);
    expect(notifier.hasMore, true);
    expect(notifier.nextCursor, 'c2');
  });

  test('loadMore appends and advances the cursor', () async {
    var calls = 0;
    final p = _provider((cursor) async {
      calls++;
      if (cursor == null) {
        return const PaginatedPage(
          items: [_Item('a', 'A')],
          hasMore: true,
          nextCursor: 'c2',
        );
      }
      expect(cursor, 'c2');
      return const PaginatedPage(
        items: [_Item('b', 'B')],
        hasMore: false,
        nextCursor: null,
      );
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(p.future);
    await container.read(p.notifier).loadMore();

    final state = container.read(p);
    expect(state.requireValue.map((i) => i.id), ['a', 'b']);
    expect(container.read(p.notifier).hasMore, false);
    expect(calls, 2);
  });

  test('loadMore is a no-op when hasMore is false', () async {
    var calls = 0;
    final p = _provider((cursor) async {
      calls++;
      return const PaginatedPage(
        items: [_Item('a', 'A')],
        hasMore: false,
      );
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(p.future);
    await container.read(p.notifier).loadMore();
    expect(calls, 1);
  });

  test('loadMore failure preserves data and reverts cursor', () async {
    final p = _provider((cursor) async {
      if (cursor == null) {
        return const PaginatedPage(
          items: [_Item('a', 'A')],
          hasMore: true,
          nextCursor: 'c2',
        );
      }
      throw StateError('boom');
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(p.future);
    final notifier = container.read(p.notifier);
    expect(notifier.nextCursor, 'c2');

    await notifier.loadMore();
    final state = container.read(p);
    expect(state.requireValue.map((i) => i.id), ['a']);
    expect(notifier.nextCursor, 'c2',
        reason: 'cursor reverts to last known good');
  });

  test('refresh re-fetches first page in place', () async {
    var page = 0;
    final p = _provider((cursor) async {
      page++;
      return PaginatedPage(
        items: [_Item('a$page', 'A$page')],
        hasMore: false,
      );
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(p.future);
    await container.read(p.notifier).refresh();

    expect(container.read(p).requireValue.first.id, 'a2');
  });

  test('prependItem and appendItem mutate the list', () async {
    final p = _provider((_) async => const PaginatedPage(
          items: [_Item('b', 'B')],
          hasMore: false,
        ));
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(p.future);
    final notifier = container.read(p.notifier);
    notifier.prependItem(const _Item('a', 'A'));
    notifier.appendItem(const _Item('c', 'C'));
    expect(container.read(p).requireValue.map((i) => i.id), ['a', 'b', 'c']);
  });

  test('updateItem replaces the matching item', () async {
    final p = _provider((_) async => const PaginatedPage(
          items: [_Item('a', 'A'), _Item('b', 'B')],
          hasMore: false,
        ));
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(p.future);
    container
        .read(p.notifier)
        .updateItem((i) => i.id == 'a', (i) => i.copyWith(title: 'A!'));
    final items = container.read(p).requireValue;
    expect(items.firstWhere((i) => i.id == 'a').title, 'A!');
  });

  test('removeItem drops the matching item', () async {
    final p = _provider((_) async => const PaginatedPage(
          items: [_Item('a', 'A'), _Item('b', 'B')],
          hasMore: false,
        ));
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(p.future);
    container.read(p.notifier).removeItem((i) => i.id == 'a');
    expect(container.read(p).requireValue.map((i) => i.id), ['b']);
  });

  test('sortItems is reapplied after mutations', () async {
    final p = _provider(
      (_) async => const PaginatedPage(
        items: [_Item('b', 'B'), _Item('a', 'A')],
        hasMore: false,
      ),
      sortByTitle: true,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(p.future);
    expect(container.read(p).requireValue.map((i) => i.id), ['a', 'b']);

    container.read(p.notifier).appendItem(const _Item('aa', 'AA'));
    expect(container.read(p).requireValue.map((i) => i.id), ['a', 'aa', 'b']);
  });

  test('applyOptimistic commits and keeps the change', () async {
    final p = _provider(
      (_) async => const PaginatedPage(
        items: [_Item('a', 'A'), _Item('b', 'B')],
        hasMore: false,
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(p.future);

    var commitCalls = 0;
    await container.read(p.notifier).applyOptimistic<void>(
          predicate: (i) => i.id == 'a',
          transform: (i) => i.copyWith(title: 'A-renamed'),
          commit: (_) async {
            commitCalls++;
          },
        );

    expect(commitCalls, 1);
    expect(
      container.read(p).requireValue.firstWhere((i) => i.id == 'a').title,
      'A-renamed',
    );
  });

  test('applyOptimistic reverts on commit failure and rethrows', () async {
    final p = _provider(
      (_) async => const PaginatedPage(
        items: [_Item('a', 'A')],
        hasMore: false,
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(p.future);

    Object? caught;
    try {
      await container.read(p.notifier).applyOptimistic<void>(
        predicate: (i) => i.id == 'a',
        transform: (i) => i.copyWith(title: 'BOOM'),
        commit: (_) async {
          throw StateError('server rejected');
        },
      );
    } catch (e) {
      caught = e;
    }

    expect(caught, isA<StateError>());
    expect(
      container.read(p).requireValue.firstWhere((i) => i.id == 'a').title,
      'A',
      reason: 'optimistic edit must revert on commit failure',
    );
  });

  test('applyOptimisticRemoval restores on failure', () async {
    final p = _provider(
      (_) async => const PaginatedPage(
        items: [_Item('a', 'A'), _Item('b', 'B')],
        hasMore: false,
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(p.future);

    Object? caught;
    try {
      await container.read(p.notifier).applyOptimisticRemoval<void>(
            predicate: (i) => i.id == 'a',
            commit: () async => throw StateError('forbidden'),
          );
    } catch (e) {
      caught = e;
    }

    expect(caught, isA<StateError>());
    expect(container.read(p).requireValue.map((i) => i.id), ['a', 'b']);
  });

  // =====================================================================
  // riverpod 3 semantics. Compile-clean changes, so they are settled by test.
  //
  // NOTE ON SUBSCRIBING: `container.read(p)` does NOT subscribe under riverpod
  // 3 — it opens and immediately closes a subscription, and an unlistened
  // provider is paused. These tests use `container.listen(...)`.
  // =====================================================================

  group('AsyncValue.value semantics (riverpod 3.3.2)', () {
    test(
        'an AsyncError that HAS a previous value keeps exposing those items — '
        'so a mutation after a failed load does NOT drop the list', () async {
      final p = _provider((cursor) async {
        if (cursor == null) {
          return const PaginatedPage(
            items: [_Item('a', 'A')],
            hasMore: true,
            nextCursor: 'c2',
          );
        }
        throw StateError('page 2 boom');
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(p, (previous, next) {});

      await container.read(p.future);
      final n = container.read(p.notifier);
      await n.loadMore(); // passes through AsyncError, then restores AsyncData

      expect(n.currentItems, isNotNull,
          reason: 'the previous page must survive the failed loadMore');
      expect(n.currentItems!.map((i) => i.id), ['a']);

      // The helper the TRD flagged as the risk: a mutation right after a
      // failure must build on the surviving items, not on an empty list.
      n.prependItem(const _Item('z', 'Z'));
      expect(container.read(p).requireValue.map((i) => i.id), ['z', 'a'],
          reason: 'prependItem after a failed loadMore must preserve item a');

      n.updateItem((i) => i.id == 'a', (i) => i.copyWith(title: 'A!'));
      expect(
        container.read(p).requireValue.firstWhere((i) => i.id == 'a').title,
        'A!',
      );
    });

    test(
        'items survive while state is DURABLY AsyncError — a failed refresh, '
        'not a loadMore that closes its own error window', () async {
      // The loadMore test above is NOT sufficient on its own: loadMore's catch
      // block immediately restores AsyncData, so the AsyncError window never
      // outlives the call and an accessor that mishandles AsyncError (e.g.
      // state.asData?.value) still passes it. refresh() uses AsyncValue.guard
      // and LEAVES state as AsyncError, which is the state consumers actually
      // observe and mutate on top of.
      var page = 0;
      final p = _provider((cursor) async {
        page++;
        if (page == 1) {
          return const PaginatedPage(items: [_Item('a', 'A')], hasMore: false);
        }
        throw StateError('refresh boom');
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(p, (previous, next) {});
      await container.read(p.future);

      final n = container.read(p.notifier);
      await n.refresh();

      expect(container.read(p).hasError, isTrue,
          reason: 'precondition: state is durably AsyncError here');
      expect(container.read(p).hasValue, isTrue,
          reason: 'riverpod 3 retains the previous value through the error');
      expect(container.read(p).asData, isNull,
          reason: 'and asData is null in exactly this state — which is why '
              'asData is the WRONG accessor for currentItems');

      expect(n.currentItems, isNotNull,
          reason: 'the loaded page must remain visible under the error');
      expect(n.currentItems!.map((i) => i.id), ['a']);

      n.prependItem(const _Item('z', 'Z'));
      expect(container.read(p).requireValue.map((i) => i.id), ['z', 'a'],
          reason: 'a mutation over a durable AsyncError must preserve item a, '
              'not silently start from an empty list');
    });

    test(
        'a mutating helper does NOT overwrite a valueless AsyncError with a '
        'fabricated list', () async {
      // build() itself fails, so there is no previous value at all. This is the
      // case riverpod 3 changed: `state.value` used to rethrow the error out of
      // these void helpers; now it returns null, and `?? const []` would turn a
      // hard error into AsyncData(['z']) — silently discarding the error and
      // showing the user a list containing one item they never had.
      final p = _provider((cursor) async => throw StateError('build boom'));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(p, (previous, next) {});
      try {
        await container.read(p.future);
      } catch (_) {}

      final n = container.read(p.notifier);
      expect(n.currentItems, isNull,
          reason: 'no list has ever been produced');
      expect(container.read(p).hasError, isTrue);

      n.prependItem(const _Item('z', 'Z'));
      n.appendItem(const _Item('y', 'Y'));
      n.updateItem((i) => true, (i) => i.copyWith(title: 'nope'));
      n.removeItem((i) => true);

      expect(container.read(p).hasError, isTrue,
          reason: 'the error state must survive every local mutation helper');
      expect(container.read(p).hasValue, isFalse,
          reason: 'no fabricated AsyncData may appear over the error');
    });

    test(
        'applyOptimistic over a valueless error still runs commit but leaves '
        'the error intact', () async {
      final p = _provider((cursor) async => throw StateError('build boom'));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(p, (previous, next) {});
      try {
        await container.read(p.future);
      } catch (_) {}

      final n = container.read(p.notifier);
      var commitCalls = 0;
      final r = await n.applyOptimistic<String>(
        predicate: (i) => true,
        transform: (i) => i,
        commit: (_) async {
          commitCalls++;
          return 'ok';
        },
      );

      expect(r, 'ok', reason: 'the caller still gets its result');
      expect(commitCalls, 1, reason: 'commit is not silently skipped');
      expect(container.read(p).hasError, isTrue);
      expect(container.read(p).hasValue, isFalse);
    });

    test(
        'loadMore is deliberately NOT guarded: it can recover a valueless '
        'error state, because it fetches real data', () async {
      // Added after mutation testing: applying the no-fabrication guard to
      // loadMore as well SURVIVED the suite, even though the production comment
      // claims loadMore is exempt on purpose. This pins the exemption.
      var calls = 0;
      final p = _provider((cursor) async {
        calls++;
        if (calls == 1) throw StateError('first load boom');
        return const PaginatedPage(items: [_Item('a', 'A')], hasMore: false);
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(p, (previous, next) {});
      try {
        await container.read(p.future);
      } catch (_) {}

      final n = container.read(p.notifier);
      expect(n.currentItems, isNull, reason: 'precondition: nothing loaded');
      expect(container.read(p).hasError, isTrue);

      await n.loadMore();

      expect(container.read(p).hasValue, isTrue,
          reason: 'loadMore fetched real data, so promoting the error state to '
              'AsyncData is recovery, not fabrication');
      expect(container.read(p).requireValue.map((i) => i.id), ['a']);
      expect(calls, 2);
    });

    test(
        'currentItems distinguishes "no list yet" from "an empty list" — a '
        'plain null/empty check could not', () async {
      final empty = _provider(
          (cursor) async => const PaginatedPage(items: [], hasMore: false));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(empty, (previous, next) {});
      await container.read(empty.future);

      final n = container.read(empty.notifier);
      expect(n.currentItems, isNotNull,
          reason: 'a successfully loaded EMPTY list is a value, not an absence');
      expect(n.currentItems, isEmpty);

      // and the helpers must work normally on it
      n.prependItem(const _Item('a', 'A'));
      expect(container.read(empty).requireValue.map((i) => i.id), ['a'],
          reason: 'mutating a legitimately-empty list must NOT be a no-op');
    });

    test('mid-refresh AsyncLoading keeps exposing the previous items',
        () async {
      var page = 0;
      final p = _provider((cursor) async {
        page++;
        if (page == 1) {
          return const PaginatedPage(items: [_Item('a', 'A')], hasMore: false);
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return const PaginatedPage(items: [_Item('b', 'B')], hasMore: false);
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(p, (previous, next) {});
      await container.read(p.future);

      final n = container.read(p.notifier);
      final refreshing = n.refresh(); // sets AsyncLoading
      expect(container.read(p).isLoading, isTrue);
      expect(n.currentItems, isNotNull,
          reason: 'AsyncLoading retains the previous value in riverpod 3, so a '
              'mutation during a refresh must not be treated as "no list yet"');
      expect(n.currentItems!.map((i) => i.id), ['a']);
      await refreshing;
    });
  });

  group('Notifier lifecycle (riverpod 3.3.2)', () {
    test('_nextCursor/_hasMore are reset by build() on a provider rebuild',
        () async {
      // Fixture is DISCRIMINATING on purpose: the second build returns a
      // different cursor and hasMore=false, so "reset" and "retained" produce
      // visibly different answers. A fixture whose two pages agree proves
      // nothing.
      var builds = 0;
      final p = _provider((cursor) async {
        if (cursor == null) builds++;
        if (builds == 1) {
          return const PaginatedPage(
            items: [_Item('a', 'A')],
            hasMore: true,
            nextCursor: 'c2',
          );
        }
        return const PaginatedPage(items: [_Item('x', 'X')], hasMore: false);
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(p, (previous, next) {});

      await container.read(p.future);
      final n1 = container.read(p.notifier);
      expect(n1.nextCursor, 'c2');
      expect(n1.hasMore, isTrue);

      container.invalidate(p);
      await container.read(p.future);
      final n2 = container.read(p.notifier);

      expect(n2.nextCursor, isNull,
          reason: 'build() assigns _nextCursor = null before fetching');
      expect(n2.hasMore, isFalse, reason: 'and takes hasMore from the new page');
      expect(container.read(p).requireValue.map((i) => i.id), ['x']);
      expect(builds, 2, reason: 'sanity: the rebuild really happened');
    });

    test(
        'a rebuild whose fetch FAILS still clears the stale cursor/hasMore',
        () async {
      // Added after mutation testing. The test above did not cover build()'s
      // opening `_nextCursor = null; _hasMore = true;` — on the success path
      // both fields are overwritten from the fetched page anyway, so deleting
      // those two lines SURVIVED. They are only load-bearing when fetchPage
      // throws, and they matter because riverpod 3 REUSES the notifier instance
      // across a rebuild (measured: identical before/after invalidate), so
      // fields living outside `state` are NOT wiped for you.
      var builds = 0;
      final p = _provider((cursor) async {
        builds++;
        if (builds == 1) {
          return const PaginatedPage(
            items: [_Item('a', 'A')],
            hasMore: false,
            nextCursor: 'c2',
          );
        }
        throw StateError('rebuild boom');
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(p, (previous, next) {});

      await container.read(p.future);
      final n1 = container.read(p.notifier);
      expect(n1.nextCursor, 'c2');
      expect(n1.hasMore, isFalse);

      container.invalidate(p);
      try {
        await container.read(p.future);
      } catch (_) {}
      final n2 = container.read(p.notifier);

      expect(n2.nextCursor, isNull,
          reason: 'a failed rebuild must not leave a cursor pointing into the '
              'previous pagination — a later loadMore would send it');
      expect(n2.hasMore, isTrue,
          reason: 'and must not leave hasMore=false, which would permanently '
              'dead-end loadMore after one failed refresh');
      expect(builds, 2, reason: 'sanity: the failing rebuild really ran');
    });
  });
}
