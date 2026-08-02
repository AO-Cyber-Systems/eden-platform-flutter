import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Outcome of a single page fetch in [PaginatedAsyncNotifier].
///
/// Repositories return one of these from [PaginatedAsyncNotifier.fetchPage].
/// The notifier internally tracks `nextCursor` and `hasMore`; subclasses
/// only have to implement the page-fetch and (optionally) the sort.
@immutable
class PaginatedPage<T> {
  const PaginatedPage({
    required this.items,
    required this.hasMore,
    this.nextCursor,
  });

  final List<T> items;
  final bool hasMore;
  final String? nextCursor;
}

/// Generic Riverpod cursor-paginated notifier.
///
/// ## What it pins down
///
/// Every "list of T loaded a page at a time, append on scroll, with optional
/// optimistic mutations" provider repeats the same boilerplate:
///
/// - track `_nextCursor` and `_hasMore`
/// - first-page fetch in `build()`
/// - `loadMore()` that appends + reverts cursor on failure
/// - optimistic create/update/delete that swaps `state` and rolls back on error
///
/// `PaginatedAsyncNotifier<T>` extracts that pattern. Subclasses implement
/// `fetchPage(cursor)` and read [currentItems] for the current items — NOT
/// `state.value` directly, whose riverpod 3 semantics are subtle enough to be
/// worth documenting in exactly one place; the base
/// class owns the cursor + hasMore state and provides ready-made
/// `loadMore`, `prependItem`, `removeItem`, `updateItem`, and
/// `applyOptimistic` helpers that handle revert-on-error.
///
/// ## Subclass example
///
/// ```dart
/// final conversationsProvider = AsyncNotifierProvider<
///     ConversationsNotifier, List<Conversation>>(ConversationsNotifier.new);
///
/// class ConversationsNotifier
///     extends PaginatedAsyncNotifier<Conversation> {
///   @override
///   Future<PaginatedPage<Conversation>> fetchPage(String? cursor) async {
///     final repo = ref.read(conversationRepositoryProvider);
///     final result = await repo.list(cursor: cursor);
///     return PaginatedPage(
///       items: result.items,
///       hasMore: result.hasMore,
///       nextCursor: result.nextCursor,
///     );
///   }
///
///   Future<Conversation> create() async {
///     final repo = ref.read(conversationRepositoryProvider);
///     final created = await repo.create();
///     prependItem(created);
///     return created;
///   }
///
///   Future<void> rename(String id, String title) =>
///       applyOptimistic<Conversation>(
///         predicate: (c) => c.id == id,
///         transform: (c) => c.copyWith(title: title),
///         commit: (_) async {
///           final repo = ref.read(conversationRepositoryProvider);
///           await repo.update(id, title: title);
///         },
///       );
/// }
/// ```
abstract class PaginatedAsyncNotifier<T> extends AsyncNotifier<List<T>> {
  String? _nextCursor;
  bool _hasMore = true;

  /// Whether more pages are available beyond what's currently in [state].
  bool get hasMore => _hasMore;

  /// The cursor that would be passed to the next [fetchPage] call.
  String? get nextCursor => _nextCursor;

  /// Subclasses fetch one page given the cursor (null for the first page).
  ///
  /// Return [PaginatedPage] with the items, the `hasMore` flag, and the
  /// next cursor (null when exhausted).
  @protected
  Future<PaginatedPage<T>> fetchPage(String? cursor);

  /// Optional hook to sort items after a mutation.
  ///
  /// Default no-op; override to keep the list in (e.g.) "pinned first, then
  /// recency desc" order after a [prependItem] / [updateItem].
  @protected
  void sortItems(List<T> items) {}

  /// The items currently held by [state], or `null` if this notifier has never
  /// successfully produced a list.
  ///
  /// ## Why this exists — riverpod 3 changed `AsyncValue.value`
  ///
  /// This is the single place the raw read happens. Every mutating helper below
  /// goes through it, so the post-error/post-loading read path is one decision
  /// in one place instead of seven undocumented copies of `state.value ?? []`.
  ///
  /// Measured against the resolved **riverpod 3.3.2**, not recalled:
  ///
  /// | `state`                          | `.value` | `.asData?.value` | `.hasValue` |
  /// |----------------------------------|----------|------------------|-------------|
  /// | `AsyncData`                      | items    | items            | true        |
  /// | `AsyncError` **with** a previous | items    | **null**         | true        |
  /// | `AsyncError` **no** previous     | null     | null             | false       |
  /// | `AsyncLoading` mid-refresh       | items    | **null**         | true        |
  /// | `AsyncLoading` never loaded      | null     | null             | false       |
  ///
  /// Two consequences that are easy to get backwards:
  ///
  /// 1. **`state.value` is the correct accessor here, and `state.asData?.value`
  ///    is not.** `asData` is null for *any* non-`AsyncData` state, so reading
  ///    through it would discard the retained items in exactly the error and
  ///    mid-refresh cases this class cares about — the opposite of the intent.
  /// 2. **riverpod 3 no longer throws from this read.** Under riverpod 2,
  ///    `AsyncValue.value` on a valueless error state rethrew the error
  ///    (`riverpod-2.6.1/lib/src/common.dart:493`); under 3 it returns `null`
  ///    (`riverpod-3.3.2/lib/src/core/async_value.dart:551`). The version bump
  ///    therefore turned a loud failure into a silent one. `hasValue` — not a
  ///    null-check on a list that is legitimately empty — is what distinguishes
  ///    "no list yet" from "an empty list", so the helpers below use it to
  ///    refuse to fabricate data over an error. See doc/riverpod-3-migration.md
  ///    §3.5.
  List<T>? get currentItems => state.hasValue ? state.value : null;

  @override
  Future<List<T>> build() async {
    _nextCursor = null;
    _hasMore = true;
    final page = await fetchPage(null);
    _hasMore = page.hasMore;
    _nextCursor = page.nextCursor;
    final items = [...page.items];
    sortItems(items);
    return items;
  }

  /// Refresh from page one. Re-runs [build] semantics in place.
  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      _nextCursor = null;
      _hasMore = true;
      final page = await fetchPage(null);
      _hasMore = page.hasMore;
      _nextCursor = page.nextCursor;
      final items = [...page.items];
      sortItems(items);
      return items;
    });
  }

  /// Load the next page and append to [state].
  ///
  /// Reverts the cursor and keeps existing data if the page fetch fails.
  Future<void> loadMore() async {
    if (!_hasMore) return;
    // Deliberately NOT guarded on [currentItems] being non-null: unlike the
    // local-mutation helpers below, loadMore fetches real data, so producing
    // AsyncData from an error state is a legitimate recovery rather than a
    // fabrication.
    final existing = currentItems ?? const [];
    final previousCursor = _nextCursor;
    try {
      final page = await fetchPage(_nextCursor);
      _hasMore = page.hasMore;
      _nextCursor = page.nextCursor;
      final next = [...existing, ...page.items];
      sortItems(next);
      state = AsyncData(next);
    } catch (e, st) {
      _nextCursor = previousCursor;
      state = AsyncError(e, st);
      // Restore data so UI keeps showing existing items after the error
      // surface (callers can `ref.listen` on the provider to show a banner).
      state = AsyncData(existing);
    }
  }

  /// Prepend an item to the list. Re-applies [sortItems] afterward.
  ///
  /// No-op while [currentItems] is null (see [currentItems]).
  void prependItem(T item) {
    final existing = currentItems;
    if (existing == null) return;
    final next = [item, ...existing];
    sortItems(next);
    state = AsyncData(next);
  }

  /// Append an item to the list. Re-applies [sortItems] afterward.
  ///
  /// No-op while [currentItems] is null (see [currentItems]).
  void appendItem(T item) {
    final existing = currentItems;
    if (existing == null) return;
    final next = [...existing, item];
    sortItems(next);
    state = AsyncData(next);
  }

  /// Remove the first item matching [predicate]. No-op if no match.
  ///
  /// Also a no-op while [currentItems] is null (see [currentItems]).
  void removeItem(bool Function(T item) predicate) {
    final existing = currentItems;
    if (existing == null) return;
    final next = existing.where((i) => !predicate(i)).toList();
    state = AsyncData(next);
  }

  /// Replace the first item matching [predicate] with [transform(old)].
  /// No-op if no match.
  ///
  /// Also a no-op while [currentItems] is null (see [currentItems]).
  void updateItem(
    bool Function(T item) predicate,
    T Function(T item) transform,
  ) {
    final existing = currentItems;
    if (existing == null) return;
    final next = existing
        .map((i) => predicate(i) ? transform(i) : i)
        .toList(growable: false);
    sortItems(next);
    state = AsyncData(next);
  }

  /// Replace the entire list. Use sparingly — prefer the granular helpers.
  void replaceAll(List<T> items) {
    final next = [...items];
    sortItems(next);
    state = AsyncData(next);
  }

  /// Apply an optimistic transform to matching items, then run [commit].
  /// On failure, restores the prior list and rethrows.
  ///
  /// Useful for `rename`/`pin`/`archive` style mutations where the UI
  /// should reflect the change immediately and roll back on error.
  /// While [currentItems] is null there is nothing to be optimistic about, so
  /// [commit] still runs (the caller awaits its result) but [state] is left
  /// alone — an error state is not overwritten with a fabricated list.
  Future<R> applyOptimistic<R>({
    required bool Function(T item) predicate,
    required T Function(T item) transform,
    required Future<R> Function(List<T> updated) commit,
  }) async {
    final existing = currentItems;
    if (existing == null) return commit(const []);
    final updated = existing
        .map((i) => predicate(i) ? transform(i) : i)
        .toList(growable: false);
    sortItems(updated);
    state = AsyncData(updated);
    try {
      return await commit(updated);
    } catch (_) {
      state = AsyncData(existing);
      rethrow;
    }
  }

  /// Optimistically remove items matching [predicate], then run [commit].
  /// Restores on failure and rethrows.
  ///
  /// While [currentItems] is null, [commit] still runs but [state] is left
  /// alone (same rule as [applyOptimistic]).
  Future<R> applyOptimisticRemoval<R>({
    required bool Function(T item) predicate,
    required Future<R> Function() commit,
  }) async {
    final existing = currentItems;
    if (existing == null) return commit();
    final updated = existing.where((i) => !predicate(i)).toList();
    state = AsyncData(updated);
    try {
      return await commit();
    } catch (_) {
      state = AsyncData(existing);
      rethrow;
    }
  }
}
