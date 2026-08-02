# riverpod 2 → 3 migration — the staged plan

**Owner:** AOID objective 50 (`aoid/.planning/objectives/50-aoid-flutter-embed-sdk-…`).
**Status:** Stage A landed (TRD 50-06). Stages B–D outstanding.
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
| `lib/src/auth/auth_provider.dart` | `AuthNotifier` (`:94`), `authProvider` (`:493`) | 499 | **50-21** |
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

**What Stage A did about it — 50-20 please VERIFY rather than duplicate:**

* `lib/src/providers/mutation_notifier.dart:184` — `AutoDisposeMutationNotifier<T>` was
  re-based from `extends AutoDisposeNotifier<MutationState<T>>` to
  **`extends Notifier<MutationState<T>>`**. That is the minimum edit that compiles. Its
  body is unchanged.
* `test/providers/mutation_notifier_test.dart` — the provider was changed from
  `AutoDisposeNotifierProvider<…>` to `NotifierProvider.autoDispose<…>`.

Consequence: `AutoDisposeMutationNotifier` is now behaviourally **identical** to
`MutationNotifier`; the auto-dispose semantics live at the call site. **TRD 50-20 owns
the real consolidation** — decide whether to deprecate the class in favour of
`MutationNotifier` + an auto-dispose provider, or keep it as a named alias.

**This is CONSUMER-VISIBLE.** Any consumer writing `AutoDisposeNotifierProvider<…>` or
subclassing `AutoDisposeNotifier` must change. Stage D must grep for both.

This is also the sole exception to Stage A's "no API migrated" rule, and it is a *forced*
exception rather than scope creep: the superclass ceased to exist, so the file could not
compile any other way. Everything else in `lib/` is untouched — `MutationNotifier` and
`PaginatedAsyncNotifier` already extended `Notifier`/`AsyncNotifier` before this TRD.

### 3.2 `navStateProvider` regressed — six tests, owned by 50-22

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

**Owner: 50-22.** The fix is the `Notifier` migration itself: move the microtask
bootstrap and both `ref.listen` calls **into `NavNotifier.build()`**, which is where
riverpod 3 expects a notifier's dependencies and side effects to be declared. Attempting
to patch the factory-side-effect pattern in place is not worth it — it is the pattern
riverpod 3 removed support for.

**Until 50-22 lands, this package's suite carries six known-red tests beyond its
pre-existing three.** Do not "fix" them by editing assertions.

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
