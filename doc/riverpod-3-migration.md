# riverpod 2 → 3 migration — the staged plan

**Owner:** AOID objective 50 (`aoid/.planning/objectives/50-aoid-flutter-embed-sdk-…`).
**Status:** Stage A landed (TRD 50-06) + gap-closure. Stages B–D outstanding.
**Suite:** back to its pre-Stage-A red count — **403 tests, 3 non-success**, all three
pre-existing on `origin/main`. The six `nav_provider` regressions 50-06 escalated are
**fixed**; see §3.2, and note that their root cause was *not* what 50-06 concluded.
**Authority for the consumer numbers below:** `tool/consumer_compat_gate.sh`, not this
prose. Re-run the gate; do not trust a table nobody executed.

This document exists so that TRDs 50-20 … 50-26 and every consumer owner work from one
plan instead of rediscovering the same breakages one repository at a time.

---

## 1. Why this is staged, and why the "firewall" was rejected

The alignment is split into four stages that land separately:

| Stage | What | Owning TRD(s) | State |
|---|---|---|---|
| **Stage A** | **Version axis only.** `flutter_riverpod ^2.6.1 → ^3.0.0`, every moved symbol re-imported from `legacy.dart` / `misc.dart`. No API rewritten. | **50-06** | **DONE** |
| **Stage B** | Per-notifier `StateNotifier → Notifier` rewrites, one notifier per TRD. | 50-20, 50-21, 50-22, 50-23 | TODO |
| **Stage C** | Barrel reunification — fold `networking.dart` back into `eden_platform.dart`. | 50-24 | TODO |
| **Stage D** | Consumer migrations. | 50-25 (eden-biz/flutter), 50-26 (the rest) | TODO |

**Staging is the point.** Roughly 450 call sites across 24 packages depend on this
package's riverpod surface. Landing a 499-line `AuthNotifier` rewrite *and* a
multi-package major version bump in one change would mean that when a consumer broke,
nobody could tell which half did it. Splitting the version axis from the API axis is
what makes per-consumer attribution possible at all.

**The "firewall" alternative was considered and REJECTED.** That path would have added a
riverpod-free `aoid.dart` barrel mirroring `networking.dart`, letting AODex consume the
client across the version boundary with near-zero blast radius, and left eden on
riverpod 2 indefinitely. It was proposed twice and declined twice (50-CONTEXT.md D2,
reaffirmed). The full alignment is being built. Do not re-litigate this; if a consumer
cannot be migrated, that is a **finding with a named blocker**, recorded here — never a
reason to fall back to the firewall.

The end state this aims at is named by this package's own `lib/networking.dart:8-10`:

> *"Future direction: once auth/company/nav are migrated to the flutter_riverpod 3.x
> AnnotationNotifier API, this separate entrypoint can be reunified with
> `eden_platform.dart`."*

That reunification is Stage C / TRD 50-24.

---

## 2. What Stage A actually did (TRD 50-06)

`flutter_riverpod` moved `^2.6.1 → ^3.0.0`, **resolving 3.3.2** (`riverpod` core 3.3.2).

The single most useful fact about riverpod 3 for this migration:

> **`StateNotifier` did not disappear in riverpod 3 — it moved.**

riverpod 3 split one barrel into **three**:

| Library | Exports |
|---|---|
| `package:flutter_riverpod/flutter_riverpod.dart` | Core: `Notifier`, `NotifierProvider`, `AsyncNotifier`, `Provider`, `Ref`, `ProviderScope`, … |
| `package:flutter_riverpod/legacy.dart` | Exactly eight: `StateNotifier`, `StateController`, `StateNotifierProvider`, `StateProvider`, `ChangeNotifierProvider`, `ChangeNotifierProviderFamily`, `StateNotifierProviderFamily`, `StateProviderFamily` |
| `package:flutter_riverpod/misc.dart` | `Override`, `ProviderBase`, `ProviderListenable`, the `*Family` types, `KeepAliveLink`, `ProviderException`, … |

So most sites keep compiling with **zero API change** by adding one import.

### 2.1 The temporary `legacy.dart` shims — what each Stage B TRD must delete

Each of these files carries an import marked **TEMPORARY** with its owning TRD:

| File | Notifier | Lines | Removed by |
|---|---|---:|---|
| ~~`lib/src/auth/auth_provider.dart`~~ | `AuthNotifier`, `authProvider` | 499 | **50-21 — DONE (§3.8)** |
| `lib/src/entitlements/entitlements_provider.dart` | `EntitlementsNotifier` (`:80`) | 216 | 50-23 |
| `lib/src/company/company_provider.dart` | `CompanyNotifier` (`:38`) | 161 | 50-22 |
| `lib/src/navigation/nav_provider.dart` | `NavNotifier` (`:36`) | 115 | 50-22 |
| `lib/src/settings/settings_provider.dart` | `SettingsNotifier` (`:32`) | 88 | 50-22 |

`lib/src/analytics/analytics_provider.dart` is a plain `Provider` and needed no shim.
`lib/src/providers/paginated_async_notifier.dart` already extended `AsyncNotifier` (a
riverpod-3-native class) and needed no shim.

Nine widget consumers (`ConsumerWidget` / `WidgetRef`) ride along unchanged and are
Stage C / 50-24's concern: `auth/login_screen.dart`, `auth/signup_screen.dart`,
`company/company_switcher.dart`, `entitlements/{feature_gate,plan_badge,quota_bar}.dart`,
`navigation/sidebar.dart`, `platform_shell.dart`, `settings/settings_screen.dart`.

### 2.2 The `misc.dart` shim — NOT a legacy symbol

`lib/src/aoid_riverpod/aoid_config_riverpod.dart` needed
`import 'package:flutter_riverpod/misc.dart';` because **`Override`** — the return type
of `buildAoidOverrides` (`:90`) — moved out of the main barrel into `misc.dart`. This was
not anticipated when Stage A was planned; the plan assumed `legacy.dart` was the only
extra import required.

`Override` is **not deprecated** and has no Notifier-API replacement, so unlike the
`legacy.dart` shims this import is likely permanent. 50-24 decides the final import
surface.

---

## 3. riverpod 3 semantic changes this bump surfaced

These are inputs to Stages B–D. They are the real product of Stage A.

### 3.1 `AutoDisposeNotifier` was REMOVED — the one break `legacy.dart` cannot fix

riverpod 3 **fused `AutoDisposeNotifier` into `Notifier`**. The class no longer exists
(confirmed: present at `riverpod-2.6.1/lib/src/notifier/auto_dispose.dart:26`, absent
from `riverpod-3.x`), and it is **not** among `legacy.dart`'s eight symbols — so there is
no shim for it. Auto-dispose is now a property of the **provider**, not the notifier:

```dart
// riverpod 2
final p = AutoDisposeNotifierProvider<MyNotifier, MyState>(MyNotifier.new);

// riverpod 3
final p = NotifierProvider.autoDispose<MyNotifier, MyState>(MyNotifier.new);
// (sugar for NotifierProvider(..., isAutoDispose: true))
```

`AutoDisposeNotifierProvider` as a *type* is gone too.

**What Stage A did about it (TRD 50-06):**

* `lib/src/providers/mutation_notifier.dart:184` — `AutoDisposeMutationNotifier<T>` was
  re-based from `extends AutoDisposeNotifier<MutationState<T>>` to
  **`extends Notifier<MutationState<T>>`**. That is the minimum edit that compiles. Its
  body is unchanged.
* `test/providers/mutation_notifier_test.dart` — the provider was changed from
  `AutoDisposeNotifierProvider<…>` to `NotifierProvider.autoDispose<…>`.

#### RESOLVED by TRD 50-20 — `AutoDisposeMutationNotifier<T>` is DELETED

50-06's re-base was verified (its class body was confirmed **byte-identical** to
`MutationNotifier`'s — only the superclass line differed) and then consolidated. The
class is **gone**. It is deliberately **not** a typedef or subclass alias: an alias
hides a real upstream break from every consumer and guarantees a second migration later.

**Final public shape — one notifier class, lifetime chosen on the provider:**

```dart
// keep-alive
NotifierProvider<MutationNotifier<T>, MutationState<T>>(MutationNotifier<T>.new);

// auto-dispose  (was: AutoDisposeMutationNotifier<T> + AutoDisposeNotifierProvider)
NotifierProvider<MutationNotifier<T>, MutationState<T>>(
  MutationNotifier<T>.new,
  isAutoDispose: true,
);
```

`isAutoDispose` is the real parameter name, verified against the **resolved riverpod
3.3.2** rather than inferred from `Provider`'s changelog entry:

```
riverpod-3.3.2/lib/src/providers/notifier/orphan.dart:86   super.isAutoDispose = false,
riverpod-3.3.2/lib/src/providers/notifier/orphan.dart:108  static const autoDispose = AutoDisposeNotifierProviderBuilder();
```

`NotifierProvider.autoDispose<...>(...)` is equivalent sugar; both spellings are covered
by tests.

**The behaviour is proven, not assumed** — the mechanism moved from base class to
provider flag, so `test/providers/mutation_notifier_test.dart` asserts that an
`isAutoDispose: true` provider drops its state on last-listener-detach **and** that an
otherwise identical keep-alive provider retains it through the same sequence. Mutation
tested: removing the flag kills the first test, adding it to the control kills the second.

**Consumer migration (mechanical):** replace `AutoDisposeMutationNotifier<Foo>` with
`MutationNotifier<Foo>`, and `AutoDisposeNotifierProvider<...>` with
`NotifierProvider<...>(..., isAutoDispose: true)`. The recipe in
`lib/src/providers/README.md` has been updated and carries a migration note.

**This is CONSUMER-VISIBLE.** Any consumer writing `AutoDisposeNotifierProvider<…>`,
subclassing the deleted riverpod base class, or naming `AutoDisposeMutationNotifier`
must change. Stage D (50-25 / 50-26) must grep for **all three** identifiers.

This is also the sole exception to Stage A's "no API migrated" rule, and it is a *forced*
exception rather than scope creep: the superclass ceased to exist, so the file could not
compile any other way. Everything else in `lib/` is untouched — `MutationNotifier` and
`PaginatedAsyncNotifier` already extended `Notifier`/`AsyncNotifier` before this TRD.

### 3.2 `navStateProvider` regressed — six tests. FIXED (gap-closure after 50-06)

> **STATUS: RESOLVED.** The six tests are green again. The fix was **entirely in
> `test/nav_provider_test.dart`**; `lib/` was not touched. `NavNotifier` is still a
> `StateNotifier`, and **50-22's scope is unchanged.**
>
> **The root cause below is NOT what 50-06 concluded, and the fix 50-06 attributed to
> 50-22 was empirically falsified.** Read §3.2.1 before doing anything in 50-22.

**This is a genuine riverpod 3 lifecycle change, and Stage A did NOT fix it.**

Six tests in `test/nav_provider_test.dart` moved `success → failure/error` across the
bump, with no API change on Stage A's part:

| Test | Before | After |
|---|---|---|
| `loadForCompany loads nav items for given company` | success | failure |
| `loadForCompany auto-selects first item when loaded` | success | failure |
| `select updates selectedId` | success | **error** |
| `clear resets to empty state` | success | failure |
| `error handling API error -> errorMessage set, items preserved` | success | failure |
| `auto-clear on auth logout nav clears when auth becomes unauthenticated` | success | failure |

**Cause.** `navStateProvider` (`lib/src/navigation/nav_provider.dart:83-107`) drives side
effects **from the provider factory**: a `Future.microtask` bootstrap plus two
`ref.listen` calls whose callbacks close over the just-constructed `NavNotifier`. Under
riverpod 3's revised initialization/flush ordering that wiring no longer settles.

Two distinct symptoms:

* Five tests: `loadForCompany` never runs — `items` stays `0`, `selectedId` stays `null`.
  The auth → company → nav chain no longer completes within the test's settle loop.
* `select updates selectedId`: `Bad state: Tried to use NavNotifier after 'dispose' was
  called`, thrown from `loadForCompany` (`nav_provider.dart:67`) reached via the
  `currentCompanyProvider` listener (`nav_provider.dart:103`), itself driven by an
  ancestor flush during `container.read(navStateProvider.notifier)`.

**What was ruled out** (so 50-22 does not repeat it):

* `fireImmediately: true` on the `currentCompanyProvider` listener — **tried, does not
  fix it.** Still six failures.
* `ref.listen` does *not* by itself cause the host provider to rebuild in riverpod 3
  (verified with an isolated reproduction).
* A disposed host's listener does *not* fire after `invalidate` in isolation — the break
  needs the full auth → company → nav chain, so it does not reduce to a small repro.

~~**Owner: 50-22.** The fix is the `Notifier` migration itself: move the microtask
bootstrap and both `ref.listen` calls **into `NavNotifier.build()`**…~~ — **WRONG. See
§3.2.1.** That hypothesis was tested directly and falsified.

---

#### 3.2.1 The actual root cause: riverpod 3 pauses an unlistened provider

The variable that decides pass/fail is **not which notifier API is used**. It is
**whether anything is actually listening to `navStateProvider`.**

riverpod 3.0 CHANGELOG, breaking changes:

> A provider is now considered "paused" if all of its listeners are also paused. So if a
> provider `A` is watched _only_ by a provider `B`, and `B` is currently unused, then `A`
> will be paused.

The mechanism, in `riverpod-3.3.2/lib/src/core/element.dart`:

```dart
bool get isActive => (listenerCount - pausedActiveSubscriptionCount) > 0;   // :407

void onCancel() {                                                           // :990
  subscriptions?.forEach((sub) => sub.impl.deactivate());
}
```

`onCancel()` fires when an element's `isActive` goes `true → false`, and it **deactivates
every subscription that element itself created** — for `navStateProvider`, both of its
`ref.listen` calls. A deactivated subscription does not deliver (`_notifyData` bails on
`isPaused`, `provider_subscription.dart:178`).

The six tests each did:

```dart
container.read(navStateProvider);   // "Subscribe to nav state to start the listener chain"
```

`ProviderContainer.read` opens a subscription **and closes it again immediately**. So nav
was left with **zero** listeners → inactive → `onCancel()` → both `ref.listen`
subscriptions deactivated. And because nav was nav's only route to
`currentCompanyProvider`, the pause **cascaded up the entire chain**:

```
nav (0 listeners, inactive) → currentCompanyProvider → companyStateProvider → authProvider
```

so the whole auth → company → nav chain went quiet and `items` stayed `0`. In riverpod 2
there were no pause semantics, so the one-shot `read` happened to work. The comment on
that line always claimed it subscribed; it never did.

That also explains **why `fireImmediately: true` did not fix it** (50-06 tried and
reverted it): `fireImmediately` fires once at registration time. It cannot re-activate a
subscription that is deactivated later.

And it explains the `select updates selectedId` **error** specifically — `Bad state:
Tried to use NavNotifier after 'dispose' was called`. The final
`container.read(navStateProvider.notifier)` momentarily re-activates the element, which
flushes the deferred company change, which fires nav's listener, which starts
`loadForCompany` — and then the read's subscription closes again, tearing the notifier
down while `loadForCompany` is still awaiting. The post-`await` `state =` then throws.

#### 3.2.2 The `Notifier.build()` migration would NOT have fixed this — measured

Before changing anything, a faithful mirror of `NavNotifier` was written as a riverpod-3
`Notifier` with the bootstrap microtask and **both `ref.listen` calls moved into
`build()`** — i.e. exactly the fix §3.2 used to prescribe for 50-22 — and run against the
same auth → company → nav flow:

| Wiring | one-shot `container.read` | real `container.listen` |
|---|---|---|
| `StateNotifier` + side effects in the provider factory (current `lib/`) | `items=0` **BROKEN** | `items=2` **WORKS** |
| `Notifier` + bootstrap and both listeners in `build()` (the 50-22 plan) | `items=0` **BROKEN** | `items=2` **WORKS** |

`NotifierProvider` goes through the **same** `ProviderElement.onCancel()` deactivation.
Moving the wiring into `build()` changes nothing about it. **The migration is orthogonal
to this bug.**

There is also no in-provider escape hatch: `ref.keepAlive()` only guards *disposal* of
auto-dispose providers (`mayNeedDispose` is gated on `provider.isAutoDispose`,
`element.dart:1197`) and does not stop `onCancel`; `reactivate()` is `@internal`; and a
provider cannot listen to itself. A provider genuinely cannot keep itself active in
riverpod 3.

#### 3.2.3 What was actually changed

**`test/nav_provider_test.dart` only. `lib/` is byte-identical to its post-50-06 state.**

A `subscribeNav(container)` helper was added that opens a real, long-lived subscription:

```dart
void subscribeNav(ProviderContainer container) {
  container.listen<NavState>(navStateProvider, (previous, next) {});
}
```

and the six `container.read(navStateProvider);` "subscribe" statements were replaced with
`subscribeNav(container);`. It is not closed explicitly — each test's existing
`container.dispose()` tears it down.

**No `expect` was touched.** This is not "fixing the tests by editing assertions"; it
makes the harness do the thing its own comment said it was doing. riverpod 3's
pause-when-unlistened behaviour is intentional, and real usage always satisfies it —
`sidebar.dart` reaches nav via `ref.watch(navItemsProvider)`, so a mounted widget keeps
the element active.

#### 3.2.4 For 50-22: VERIFY, do not duplicate

* `NavNotifier` is **still a `StateNotifier`**, its `legacy.dart` shim is still in place,
  and `lib/src/navigation/nav_provider.dart` is unchanged. **50-22's scope is unchanged.**
* When 50-22 migrates `NavNotifier` to `Notifier`, `test/nav_provider_test.dart` should
  keep `subscribeNav`. Per §3.2.2 the migration does **not** remove the need for it; if
  the helper is dropped, the same six tests fail again on the `Notifier` API.
* **Do not** re-attempt `fireImmediately: true` (falsified twice now) or try to make the
  provider hold itself active (§3.2.2 — no API for it).
* **DEFERRED TO 50-22 — a real crash path, deliberately not fixed here.**
  `NavNotifier.loadForCompany` assigns `state` after an `await` with **no `mounted`
  guard** — both the success path (`nav_provider.dart:61`) and the `catch` path
  (`:66`, which is where the throw actually surfaced). That is what turned `select updates
  selectedId` into an *error* rather than a plain failure. It is latent in production for
  any consumer that lets nav go unlistened mid-load. The one-line
  `if (!mounted) return;` was **not** applied here because this gap-closure was scoped to
  the minimum that restores the six tests, and 50-22 is already rewriting this method.
  **50-22 must add it** (as `Notifier`, the equivalent is `ref.mounted`).

### 3.3 A file may stop needing the main barrel entirely

`lib/src/settings/settings_provider.dart` had to **drop**
`import 'package:flutter_riverpod/flutter_riverpod.dart';`. After the split, every symbol
it uses (`StateNotifier`, `StateNotifierProvider`) comes from `legacy.dart`, and its
`ThemeMode` is this package's own enum — so the main barrel became genuinely unused and
tripped `unused_import`. It is the only such file.

**50-22 must RE-ADD that import** when migrating `SettingsNotifier`, because
`Notifier`/`NotifierProvider` live in the main barrel.

### 3.4 `example/` blocks `flutter pub get` for the whole repo

`example/pubspec.yaml` declares `flutter_riverpod` *and* depends on the parent package by
path. A 2.x pin there makes version solving fail for the entire repo, not just the
example. It was bumped to `^3.0.0` in Stage A. **The consumer table in TRD 50-06 omits
this package** — see §4.

### 3.5 `AsyncValue.value` no longer throws — the compile-clean change (TRD 50-20)

**Read this before touching any `AsyncNotifier` in 50-21 / 50-22 / 50-23.** Nothing here
produces an analyzer error; it is a pure behaviour change.

| riverpod | `AsyncValue.value` on an error state with **no** previous value |
|---|---|
| 2.6.1 (`lib/src/common.dart:493`) | **rethrows the error** |
| 3.3.2 (`lib/src/core/async_value.dart:551`) | returns **`null`** (`ValueT? get value => _value?.$1`) |

`AsyncValue.valueOrNull` was deleted; in 3.x plain `value` *is* the old `valueOrNull`.

**What `.value` actually returns, measured on 3.3.2** (not recalled — a probe test was
run against each state shape):

| `state` | `.value` | `.asData?.value` | `.hasValue` |
|---|---|---|---|
| `AsyncData` | items | items | true |
| `AsyncError` **with** a previous value | **items** | **null** | true |
| `AsyncError` **no** previous value | null | null | false |
| `AsyncLoading` mid-refresh | **items** | **null** | true |
| `AsyncLoading` never loaded | null | null | false |

Two traps fall out of that table:

1. **`state.asData?.value` is NOT a safe "explicit" replacement for `state.value`.**
   `asData` is null for *any* non-`AsyncData` state, so swapping to it silently discards
   the retained items in exactly the error and mid-refresh cases. This was proposed as
   the fix during planning and is **falsified**: substituting it breaks two tests in
   `test/providers/paginated_async_notifier_test.dart`.
2. **Assigning `state = AsyncError(e, st)` inside a notifier does NOT discard the
   previous value.** riverpod routes the assignment through
   `ElementWithFuture.onError → asyncTransition → copyWithPrevious`
   (`element.dart:67,106`), and `AsyncError.copyWithPrevious` keeps `previous._value`
   (`async_value.dart:873`). So "the error wipes my data" is false.

**The real defect, and it is inherited by every consumer subclassing
`PaginatedAsyncNotifier`.** All **seven** read sites in that class (not eleven — the
planning doc's count was wrong; its own list of affected methods names seven) read
`state.value ?? const []`. When a notifier has **never** produced a list — `build()`
itself threw — riverpod 2 made that read **rethrow the original error** out of a `void`
helper, which was loud. riverpod 3 returns `null`, so `?? const []` substitutes an empty
list and the helper then writes `state = AsyncData([...])` — **silently replacing a hard
error state with a fabricated one-item list and discarding the error.** The user sees a
list containing an item they never had, instead of the error.

To be precise about the pre-bump behaviour, because it is easy to overstate: riverpod 2
did **not** silently drop items the user already had — with a previous value present,
`hasValue` was true and the read returned those items, same as 3.x. The regression is
confined to the *valueless* error/loading case, where 2.x threw and 3.x fabricates.

**Fix applied in 50-20.** The seven sites are replaced by one documented accessor:

```dart
List<T>? get currentItems => state.hasValue ? state.value : null;
```

`hasValue` — not a null/empty check on the list, which would conflate "no list yet" with
"a legitimately empty list" — is the predicate that distinguishes the two. The six
local-mutation helpers (`prependItem`, `appendItem`, `removeItem`, `updateItem`,
`applyOptimistic`, `applyOptimisticRemoval`) now refuse to write data over a valueless
error. `loadMore` is deliberately **exempt**: it fetches real data, so promoting an error
state to `AsyncData` is recovery, not fabrication. Both the rule and the exemption are
pinned by test, and both were confirmed by mutation.

### 3.6 A `Notifier` instance is REUSED across a rebuild — fields are not wiped for you

The planning material asserted that riverpod 3 recreates `Notifier` instances on every
rebuild, and that therefore fields living outside `state` are volatile. **Measured on
3.3.2, the opposite is true for `invalidate`:** the notifier instance before and after
`container.invalidate(p)` is `identical`, and `build()` simply re-runs on it.

Consequence for 50-21 / 50-22 / 50-23: **any field a notifier keeps outside `state` must
be reset explicitly at the top of `build()`** — nothing wipes it. `PaginatedAsyncNotifier`
already does this (`_nextCursor = null; _hasMore = true;`). Those two lines look redundant
because the success path overwrites both from the fetched page; they are load-bearing only
when `fetchPage` **throws**, where without them a failed rebuild leaves a stale cursor
pointing into the previous pagination and can permanently dead-end `loadMore`. Deleting
them survived the suite until a test was written for the failing-rebuild path.

### 3.7 `==` filtering + `const` sentinels — when a state assignment does NOT notify

riverpod 3 filters **all** provider updates with `==`. `MutationState` deliberately does
not override `==`, so `==` is identity, and that interacts with `const`:

| assignment | notifies? | why |
|---|---|---|
| `state = const MutationState.inFlight()` (repeat) | **no** | const-canonicalized: the identical instance |
| `state = const MutationState.idle()` (repeat) | **no** | same |
| `reset()` → `state = MutationState<T>.idle()` (repeat) | **yes** | not const; allocates fresh, so identity differs |

Two nearly identical lines with different notification behaviour. Both are intentional and
are pinned by `test/providers/mutation_notifier_test.dart`. Value equality was
**deliberately not added** to `MutationState`: it would also collapse a genuine re-`run`
that produced an equal result, and UIs legitimately re-trigger on a repeated success.

**For 50-21 / 50-22 / 50-23:** any state class that is `const`-constructed and lacks a
value `==` inherits this. A notifier that relies on "assign the sentinel again to force a
rebuild" is broken under riverpod 3.

---

### 3.8 The suppressed sign-out — measured at the epicentre (TRD 50-21)

`AuthNotifier` is the first place §3.7's pattern met a **security-relevant** signal, so it
was measured rather than reasoned about. The headline is a correction:

> **This is NOT a riverpod 3 regression. The sign-out notification was already being
> suppressed under `StateNotifier`, and was suppressed under riverpod 2 as well.**

**What was measured.** A probe registered a listener on `authProvider`, let boot settle to
`unauthenticated`, then called `logout()` twice.

| implementation | listener fires |
|---|---:|
| `StateNotifier` (Stage A, riverpod 3) | **0** |
| `Notifier`, riverpod 3 default `updateShouldNotify` | **0** |
| `Notifier` + `updateShouldNotify => true` (shipped) | **2** |

**Why the two base classes behave identically.** They use *different* predicates that
happen to coincide for `AuthState`:

- riverpod 3 `Notifier` → `ProviderElement.defaultUpdateShouldNotify` → `previous != next`
  (`riverpod-3.3.2/lib/src/core/element.dart:372-374`)
- legacy `StateNotifier` → `StateNotifier.updateShouldNotify` → `!identical(old, current)`
  (`state_notifier-1.0.0/lib/state_notifier.dart:203-207`), which `StateNotifierProvider`'s
  element delegates to (`riverpod-3.3.2/lib/src/providers/legacy/state_notifier_provider.dart:181-185`)

`AuthState` declares **no `operator ==`**, so `!=` degrades to non-identity and the two
predicates are the same test. Combined with `const AuthState.unauthenticated()` being one
canonicalized object forever, a repeat sign-out is invisible to listeners either way.

There *is* one real behavioural difference between the two, worth knowing: on a filtered
assignment `StateNotifier` leaves riverpod's element value **stale** (the setter early-returns
before publishing), whereas `Notifier` stores the new value and only skips the listener
notification. So `container.read(authProvider)` reads correctly post-filter under `Notifier`
and did not under `StateNotifier`.

**The fix, and why it is on the notifier.** `AuthNotifier` overrides
`updateShouldNotify => true`, which riverpod's own 3.0.0 changelog names as the escape
hatch. `AuthState` was deliberately **not** given an `operator ==`: that would change
equality for every consumer in 18+ packages to fix one notification. The override's blast
radius is one provider.

**Who is exposed to the identical shape — 50-22 and 50-23 must check, not assume.**
`CompanyState`, `NavState`, `SettingsState` and `EntitlementsState` all have `const`
constructors and all get assigned `state = const XState()` from their `clear()` methods —
and `clear()` is exactly what they call on the sign-out signal. So the pattern nests: a
sign-out that *does* now propagate can still be dropped a second time inside the listener,
if `clear()` re-assigns a sentinel the provider is already holding. Measure each one the
way §3.8 measures this one; a `greaterThanOrEqualTo(1)` assertion will not see it.

**For 50-25 / 50-26:** consumer packages that assign a `const` sentinel in their own
sign-out paths inherit this too. It is not something the eden upgrade fixes for them,
because it was never introduced by the upgrade.

### 3.9 Two dartdoc lint traps that have now bitten twice

`unintended_html_in_doc_comment` fired in 50-20 and again in 50-21 for the same reason: a
backtick-wrapped generic (`` `Foo<Bar>` ``) **line-wrapped inside a dartdoc comment**. The
analyzer does not pair backticks across lines, so the `<Bar>` reads as an HTML tag. Keep
any backticked generic on one line, or reword. `flutter analyze` is clean before and after
each Stage B TRD only because this was caught by a finding-set diff, not by eye —
**50-22 and 50-23 will hit it too.**

Related: `unnecessary_underscores` fires on `(_, __)` listener lambdas. riverpod's
`container.listen` callbacks want `(_, _)` under the current lint set.

---

## 4. The measured consumer table

Generated by `tool/consumer_compat_gate.sh`; the committed before-state lives at
`aoid/.planning/reports/50-06-consumer-compat-before.txt`. Counts are **import-site
occurrences** across `lib/ test/ integration_test/ test_driver/`.

### 4.1 Reconciling 24 packages against the plan's "18"

A direct count finds **24 pubspecs** declaring `eden_platform_flutter`. TRD 50-06's table
lists 22 rows and its prose says "18 packages". All three numbers are defensible and mean
different things:

| Count | Meaning |
|---:|---|
| **24** | pubspecs declaring the dependency (the gate's Stage 1 — the authority) |
| **22** | rows in the TRD's table |
| **18** | packages importing the **riverpod-2 surface** (`eden_platform.dart` ≥ 1), i.e. 22 − the 4 networking-only ones (`aodex/flutter`, `aofamily/{ai,browser,connect}`) — this is D2's "18 packages" |

The **two packages missing from the TRD's table entirely**:

1. `eden-libs/eden-platform-flutter/example` — 1 `eden_platform.dart` site. Not
   cosmetic: it blocked `flutter pub get` (§3.4).
2. `videoAnalysis/video-analysis-flutter` — 0/0/0. Named in the TRD's *gotchas* as
   declaring the dependency while importing nothing, but absent from the table. It is
   **not an active consumer**; it needs only a constraint bump.

Per-package count differences from the TRD table (the gate is the authority):
`eden-biz/flutter` **280** (table: 284) · `eden-biz/flutter/test_support` **4** (2) ·
`eden-biz/pos` **7** (6) · `eden-platform-flutter` self **27** (22) ·
`politihub/flutter-navigators` networking **23** (22). The likely cause is scope —
the gate counts occurrences across four source directories, and the self count now
includes Stage A's own new test file.

### 4.2 The distinction that decides what any gate run proves

**13 consumers resolve eden from the local working tree** — they see Stage A right now,
including uncommitted changes. **10 are frozen at a git `ref:`** and are blind to
`obj50/aoid-module`, which is deliberately unpushed.

Resolving this correctly requires reading `dependency_overrides` **before** the
`dependencies` block, because an override wins for the root package. Two consumers
(`aoid-plans/portal`, `aoid-household/portal`) declare a frozen `ref: 6200455` and then
override eden to an absolute local path — reading only the dependencies block
misclassifies them as frozen when they are in fact live. `politihub/flutter-navigators`
and both `justinforme` apps do the same.

| Resolution | Packages |
|---|---|
| **local tree — sees Stage A NOW** (13) | `aoid-household/portal`*, `aoid-plans/portal`*, `eden-biz-mobile`, `eden-platform-flutter/example`, `justin-donnaruma-us-go/flutter`, `justinforme/flutter/admin`*, `justinforme/flutter/volunteer`*, `navigators/navigators-flutter`, `politihub/flutter`, `politihub/flutter-navigators`*, `recycling-oracle/recycling-oracle-flutter`, `smartWellness/flutter/admin`, `videoAnalysis/video-analysis-flutter` |
| **frozen git `ref:` — blind to Stage A** (10) | `aodex/flutter` `a26fb08`, `aofamily/{ai,browser,connect}/flutter` `1381e8b`, `aoid/portal` `452448f6`, `eden-biz/flutter` + `test_support` `215e868`, `eden-biz/mobile` `ad35449`, `eden-biz/pos` `ad35449`, `ops-console/flutter` `5cf168a` |

`*` = reaches the local tree via `dependency_overrides`, not via the dependencies block.

**Consequence, and it is the most important line in this document:** 12 of those 13
local-resolving consumers **fail `flutter pub get` right now**, because they declare
`flutter_riverpod ^2.4.0`/`^2.6.1` while the local eden requires `^3.0.0` and Dart
version solving rejects the combination. (The 13th, `example/`, was bumped as part of
Stage A.) The 10 frozen consumers are unaffected until someone repoints them — Stage D.

**Not every failure is Stage A's fault**, and Stage D must not be planned as if it were:

| Failing consumer | Cause |
|---|---|
| `aoid-household/portal`, `aoid-plans/portal`, `eden-biz-mobile`, `justin-donnaruma-us-go/flutter`, `justinforme/flutter/{admin,volunteer}`, `politihub/flutter`, `recycling-oracle/…`, `smartWellness/flutter/admin`, `videoAnalysis/…` (**10**) | **riverpod — caused by Stage A.** Fixed by bumping the consumer's own `flutter_riverpod` constraint to `^3.0.0`. |
| `navigators/navigators-flutter` | **PRE-EXISTING**, unrelated: eden pins `flutter_secure_storage 9.2.4`, navigators requires `^10.0.0`. Would have failed before Stage A. |
| `politihub/flutter-navigators` | **PRE-EXISTING**, unrelated: eden requires `sentry_flutter ^9.19.0`, this app requires `^8.14.2`. Would have failed before Stage A. |

Those last two are **doubly blocked** — they need their own dependency conflict resolved
*before* a riverpod bump can even be attempted. Do not schedule them as simple constraint
bumps.

**Therefore a green gate run proves nothing about the frozen consumers.** Objective 50
already made this mistake once: 50-04's portal gate analysed a `~/.pub-cache/git/`
snapshot and reported "0 new errors" while blind to the change under test. 50-26 **must**
re-run this gate after repointing each consumer's `ref:`, or it will report a false green.

---

## 5. Consumer migration order

Largest risk first, so the expensive discovery happens while there is time to react.

| # | Package(s) | Sites | Owner | Notes |
|---|---|---:|---|---|
| 1 | `eden-biz/flutter` (+ `test_support`) | **280** + 4 | **50-25, its own TRD** | By far the largest. `^2.4.0` → `^3.0.0`. Frozen at `215e868`. |
| 2 | `aodex/flutter` | 0 (82 networking) | 50-26 | Already resolves 3.2.1 and carries a `dependency_overrides` forcing `^3.0.0` — see §6. The proving consumer for SDK-03. |
| 3 | `aoid/portal` | 15 | 50-26 | |
| 4 | `justin-donnaruma-us-go/flutter` | 23 | 50-26 | `path:` — broken now. |
| 5 | `navigators/navigators-flutter` | 22 | 50-26 | `path:` — broken now. |
| 6 | `aoid-plans/portal`, `aoid-household/portal` | 13, 13 | 50-26 | Both frozen at `6200455`. |
| 7 | `politihub/flutter-navigators`, `politihub/flutter` | 13 (+23), 7 | 50-26 | `path:` — broken now. |
| 8 | `justinforme/flutter/{volunteer,admin}` | 10, 7 | 50-26 | `path:` — broken now. |
| 9 | `eden-biz-mobile`, `eden-biz/mobile` | 9, 9 | 50-26 | `eden-biz-mobile` is `path:`; `eden-biz/mobile` is frozen. |
| 10 | `eden-biz/pos` | 7 | 50-26 | |
| 11 | `recycling-oracle/…`, `smartWellness/flutter/admin` | 6, 4 | 50-26 | `path:` — broken now. |
| 12 | `ops-console/flutter` | 2 | 50-26 | Small; `test=3/3` today. |
| 13 | `aofamily/{ai,connect,browser}/flutter` | 0 (networking only) | 50-26 | Constraint bump only. |
| 14 | `videoAnalysis/video-analysis-flutter` | 0/0/0 | 50-26 | Constraint bump only; imports nothing. |

Every consumer must additionally be grepped for the §3.1 `AutoDisposeNotifier` /
`AutoDisposeNotifierProvider` break, which no shim covers.

---

## 6. `dependency_overrides` that become removable

`dependency_overrides` are honoured **only for the root package**, which is why several
consumers' overrides "work" today without eden itself moving.

* **`aodex/flutter`** carries a block forcing `flutter_riverpod: ^3.0.0`, whose own
  comment explains it is safe because *"aodex only imports the networking entrypoint
  (zero riverpod deps)"*. Stage A makes that override **redundant** — eden now genuinely
  requires 3.x. It should be removed when AODex is repointed at post-Stage-A eden. Do not
  remove it before then: while AODex is still pinned at `a26fb08` (riverpod 2), the
  override is what holds the build together.

No consumer repository was edited by Stage A or by the gate. Removals happen in Stage D.

---

## 7. Running the gate

```bash
cd ~/dev/eden-libs/eden-platform-flutter

tool/consumer_compat_gate.sh --enumerate-only          # Stage 1 only, fast
tool/consumer_compat_gate.sh --skip-tests              # + pub get + analyze
tool/consumer_compat_gate.sh --only aoid/portal        # one package
tool/consumer_compat_gate.sh --tests-for "aoid/portal,aodex/flutter"
tool/consumer_compat_gate.sh --explain-failures        # why each pub get fails
```

**Never run `flutter pub get` by hand inside a consumer to investigate a failure.**
Use `--explain-failures`. A failed `pub get` still rewrites `pubspec.lock` — sometimes
the entire transitive graph — and that churn is indistinguishable from a human's
uncommitted work once it is sitting in their working tree. This was learned the hard
way during Stage A: an ad-hoc diagnostic loop left rewritten lockfiles in
`recycling-oracle` and `justinforme`, both of which had to be reverted by hand.
`--explain-failures` does the same investigation with the backup/restore below.

The gate is **read-only**: it never edits, stages, stashes, cleans or commits in a
consumer. `flutter pub get` writes `pubspec.lock`, so the gate snapshots that file and
restores its exact bytes afterwards, and records each package's `git status --porcelain`
before and after in the `git=` column:

* `clean` — repo was clean before and after.
* `DIRTY-BEFORE(unchanged-by-gate)` — repo already held uncommitted work (several do);
  the gate left it exactly as found.
* `CHANGED-BY-GATE` — **a bug in the gate.** Investigate before trusting the run.

Output is sorted by package path and header-stamped with the date, the eden HEAD sha and
the exact command line, so before/after runs diff cleanly.
