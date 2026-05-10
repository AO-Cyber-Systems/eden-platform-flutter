# Riverpod patterns — `lib/src/providers/`

Generic Riverpod patterns donated from AODex Flutter. Two patterns ship here:

| Pattern | When you reach for it |
|---|---|
| `PaginatedAsyncNotifier<T>` | A list of `T` loaded a page at a time, with optional optimistic create/update/delete. Owns cursor + `hasMore` state. |
| `MutationNotifier<T>` (and `AutoDisposeMutationNotifier<T>`) | A single CRUD-style mutation (create, update, delete, etc.) where the UI needs to track `idle → inFlight → success | failure`. |

Both ship as plain Dart classes so consumers don't need codegen — the only
dependency is `flutter_riverpod`.

## `PaginatedAsyncNotifier<T>`

Subclass and implement `fetchPage(cursor)`:

```dart
final conversationsProvider =
    AsyncNotifierProvider<ConversationsNotifier, List<Conversation>>(
  ConversationsNotifier.new,
);

class ConversationsNotifier extends PaginatedAsyncNotifier<Conversation> {
  @override
  Future<PaginatedPage<Conversation>> fetchPage(String? cursor) async {
    final repo = ref.read(conversationRepositoryProvider);
    final result = await repo.list(cursor: cursor);
    return PaginatedPage(
      items: result.items,
      hasMore: result.hasMore,
      nextCursor: result.nextCursor,
    );
  }

  // Optional: keep pinned items first, then recency desc
  @override
  void sortItems(List<Conversation> items) {
    items.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
  }

  Future<Conversation> create() async {
    final repo = ref.read(conversationRepositoryProvider);
    final created = await repo.create();
    prependItem(created);
    return created;
  }

  Future<void> rename(String id, String title) =>
      applyOptimistic<void>(
        predicate: (c) => c.id == id,
        transform: (c) => c.copyWith(title: title),
        commit: (_) async {
          final repo = ref.read(conversationRepositoryProvider);
          await repo.update(id, title: title);
        },
      );

  Future<void> archive(String id) =>
      applyOptimisticRemoval<void>(
        predicate: (c) => c.id == id,
        commit: () async {
          final repo = ref.read(conversationRepositoryProvider);
          await repo.update(id, archived: true);
        },
      );
}
```

### What the base class owns

- `_nextCursor` and `_hasMore` private state.
- First-page fetch in `build()`.
- `loadMore()` with cursor revert + data preservation on failure.
- `prependItem`, `appendItem`, `removeItem`, `updateItem`, `replaceAll` — all
  re-apply `sortItems` so the list ordering invariant holds after any
  mutation.
- `applyOptimistic` and `applyOptimisticRemoval` for mutations that need to
  flip the UI immediately and roll back on error.

## `MutationNotifier<T>`

Two flavors, depending on lifetime:

- `MutationNotifier<T>` — keep-alive variant.
- `AutoDisposeMutationNotifier<T>` — drops state when the last listener
  detaches; use for one-off form submissions.

Most callers don't subclass — just instantiate:

```dart
final saveConversationMutation =
    AutoDisposeNotifierProvider<AutoDisposeMutationNotifier<Conversation>,
        MutationState<Conversation>>(AutoDisposeMutationNotifier<Conversation>.new);

// In the widget:
final state = ref.watch(saveConversationMutation);
final notifier = ref.read(saveConversationMutation.notifier);

EdenButton(
  label: state.isInFlight ? 'Saving…' : 'Save',
  onPressed: state.isInFlight
      ? null
      : () => notifier.run(() => repo.update(id, title)),
);

state.when(
  idle: () => const SizedBox.shrink(),
  inFlight: () => const EdenSpinner(),
  success: (saved) => Text('Saved as "${saved.title}"'),
  failure: (err, _) => EdenInlineErrorBanner(message: 'Save failed: $err'),
);
```

When the same mutation logic is reused across screens, subclass and expose
typed methods (see the docstring in `mutation_notifier.dart`).

## Testing

Both classes are designed to be tested with `ProviderContainer`:

```dart
final container = ProviderContainer(overrides: [
  conversationRepositoryProvider.overrideWithValue(fakeRepo),
]);
addTearDown(container.dispose);

// Trigger first fetch
await container.read(conversationsProvider.future);

// Drive mutations
await container.read(conversationsProvider.notifier).rename('c1', 'New');

expect(
  container.read(conversationsProvider).requireValue.first.title,
  'New',
);
```

## Origin

Both patterns are abstracted from AODex Flutter's
`features/chat/application/conversation_service.dart` (pagination + 5
optimistic mutations) plus the implicit "save form" pattern repeated across
`features/profile/`, `features/teams/`, `features/knowledge/`. The donor
code lived in `aodex-flutter/lib/src/features/*/application/` and is being
deleted as those features migrate to these base classes.
