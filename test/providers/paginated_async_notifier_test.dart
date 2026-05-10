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
}
