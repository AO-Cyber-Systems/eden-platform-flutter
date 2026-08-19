import 'dart:async';
import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_provider.dart';
import '../company/company_provider.dart';
import '../models/platform_models.dart';
import 'entitlements_models.dart';
import 'entitlements_repository.dart';

// ---------------------------------------------------------------------------
// Repository provider
// ---------------------------------------------------------------------------

/// Override this provider to set the Eden Biz base URL for entitlements.
///
/// Example in your app's ProviderScope:
/// ```dart
/// ProviderScope(
///   overrides: [
///     entitlementsRepositoryProvider.overrideWithValue(
///       HttpEntitlementsRepository(baseUrl: 'https://biz.example.com'),
///     ),
///   ],
///   child: App(),
/// )
/// ```
final entitlementsRepositoryProvider = Provider<EntitlementsRepository>((ref) {
  // Default: use the same base URL as the platform repository.
  // Apps should override this with their Eden Biz URL.
  return HttpEntitlementsRepository(baseUrl: 'http://localhost:9090');
});

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class EntitlementsState {
  final bool isLoading;
  final PlatformSubscription? subscription;
  final PlatformPlan? plan;
  final List<PlatformEntitlement> entitlements;
  final List<PlatformFeatureFlag> featureFlags;
  final String? errorMessage;

  const EntitlementsState({
    this.isLoading = false,
    this.subscription,
    this.plan,
    this.entitlements = const [],
    this.featureFlags = const [],
    this.errorMessage,
  });

  EntitlementsState copyWith({
    bool? isLoading,
    PlatformSubscription? subscription,
    PlatformPlan? plan,
    List<PlatformEntitlement>? entitlements,
    List<PlatformFeatureFlag>? featureFlags,
    String? errorMessage,
    bool clearError = false,
    bool clearSubscription = false,
  }) {
    return EntitlementsState(
      isLoading: isLoading ?? this.isLoading,
      subscription: clearSubscription ? null : (subscription ?? this.subscription),
      plan: clearSubscription ? null : (plan ?? this.plan),
      entitlements: entitlements ?? this.entitlements,
      featureFlags: featureFlags ?? this.featureFlags,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

class EntitlementsNotifier extends Notifier<EntitlementsState> {
  /// Registers the wiring that used to live in the `StateNotifierProvider`
  /// closure, then returns the initial state.
  ///
  /// `NotifierProvider(EntitlementsNotifier.new)` takes **no closure**, so the
  /// two subscriptions and the bootstrap have nowhere else to go. Two ordering
  /// rules apply, both inherited from doc/riverpod-3-migration.md §3.10.2
  /// rather than re-derived here:
  ///
  /// 1. **Both `ref.listen` calls are registered BEFORE the microtask is
  ///    scheduled**, and unconditionally. riverpod owns re-registration across
  ///    rebuilds; an "already registered" flag would leak the first
  ///    subscription and give a listener that fires once and then never again.
  ///    Measured non-behavioural on the sibling notifiers — `Future.microtask`
  ///    only *schedules*, so both statements complete synchronously inside
  ///    `build()` — but kept, because it stops being free the moment the
  ///    bootstrap stops being a microtask.
  /// 2. **The bootstrap stays a microtask.** Calling [load] directly here
  ///    would throw: it reads `state` (via the `copyWith` on the loading
  ///    transition) and `state` does not exist until `build()` RETURNS.
  ///
  /// This class keeps no fields outside `state`, so [build] has nothing to
  /// reset. That is not a general licence: a riverpod 3 [Notifier] instance is
  /// REUSED across a rebuild, unlike the `StateNotifierProvider` this replaced,
  /// which ran the constructor afresh and discarded such fields for free.
  @override
  EntitlementsState build() {
    // Clear on logout.
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (!next.isAuthenticated) {
        clear();
      }
    });

    // Reload on company switch.
    ref.listen<PlatformCompany?>(currentCompanyProvider, (previous, next) {
      if (next == null) {
        clear();
        return;
      }
      if (previous?.id != next.id) {
        load(next.id);
      }
    });

    // Auto-load when auth and company are available.
    unawaited(Future.microtask(() {
      final auth = ref.read(authProvider);
      final company = ref.read(currentCompanyProvider);
      if (auth.isAuthenticated && company != null) {
        load(company.id);
      }
    }));

    return const EntitlementsState();
  }

  /// Restores notify-on-every-assignment for this provider.
  ///
  /// riverpod 3 filters updates with `previous != next`. [EntitlementsState]
  /// declares no `operator ==`, so `!=` degrades to identity — and this
  /// notifier assigns `const EntitlementsState()` from **two** sites, [clear]
  /// and [load]'s no-access-token early return. Dart canonicalizes that const
  /// instance to one object forever, so re-assigning it to a provider that
  /// already holds it is invisible to listeners.
  ///
  /// MEASURED on this provider before the migration, with the legacy
  /// `StateNotifier` still in place — listener fires on a sign-out:
  ///
  /// | link | 1st sign-out | 2nd sign-out (already clear) |
  /// |---|---:|---:|
  /// | `entitlementsStateProvider`  | 1 | **0** |
  /// | `currentPlanProvider`        | 1 | **0** |
  /// | `currentSubscriptionProvider`| 1 | **0** |
  /// | `canUseFeatureProvider`      | 1 | **0** |
  ///
  /// So this is NOT a riverpod 3 regression and NOT a the spec regression:
  /// `StateNotifier.updateShouldNotify` defaults to `!identical(old, current)`,
  /// which for a class with no value `==` is the same predicate riverpod 3
  /// uses. The defect predates the version bump. Fourth occurrence in this
  /// alignment, after `AuthState`, `CompanyState` and `NavState`.
  ///
  /// What is lost on a suppressed repeat is the SIGNAL, not the value — the
  /// state is already the cleared sentinel. That still matters: this is the
  /// third link in the sign-out chain, and any consumer holding a `ref.listen`
  /// here to drop a cached plan or reset analytics identity never hears it.
  ///
  /// Deliberately scoped to the notifier. Giving [EntitlementsState] an
  /// `operator ==` would change equality for every consumer in 18+ packages to
  /// fix one notification. De-consting [clear] is likewise rejected: it is a
  /// silent PARTIAL fix that leaves [load]'s early return suppressed.
  @override
  bool updateShouldNotify(
          EntitlementsState previous, EntitlementsState next) =>
      true;

  Future<void> load(String companyId) async {
    final accessToken = ref.read(authProvider).accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      state = const EntitlementsState();
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final repo = ref.read(entitlementsRepositoryProvider);
      final bootstrap = await repo.bootstrap(accessToken, companyId);

      state = EntitlementsState(
        subscription: bootstrap.subscription,
        plan: bootstrap.plan,
        entitlements: bootstrap.entitlements,
        featureFlags: bootstrap.featureFlags,
      );
    } catch (error) {
      log('[Entitlements] bootstrap failed: $error');
      state = EntitlementsState(
        subscription: state.subscription,
        plan: state.plan,
        entitlements: state.entitlements,
        featureFlags: state.featureFlags,
        errorMessage: error.toString(),
      );
    }
  }

  Future<void> refresh() async {
    final company = ref.read(currentCompanyProvider);
    if (company != null) {
      await load(company.id);
    }
  }

  void clear() {
    state = const EntitlementsState();
  }
}

// ---------------------------------------------------------------------------
// Main provider (auto-loads when auth + company change)
// ---------------------------------------------------------------------------

/// Subscription, plan, entitlements and feature flags for the current company.
///
/// Loads automatically once there is both an authenticated session and a
/// current company, reloads on a company switch, and clears on sign-out.
///
/// ## These providers are UI HINTING ONLY
///
/// Neither this provider nor any of the derived ones below is an enforcement
/// point, and neither is `EdenFeatureGate`. They exist so the UI can hide,
/// disable or annotate what a plan does not include.
///
/// **The server always re-verifies** every entitlement on the request that
/// actually does the work. Treating a `true` from [canUseFeatureProvider] as
/// authorisation is a bug: the state here can be stale, overridden in a test,
/// or simply not loaded yet.
///
/// ## This is the eden-biz PLAN/BILLING axis
///
/// Everything in this file comes from eden-biz
/// `/api/v1/entitlements/bootstrap` and describes what a company has **paid
/// for** — subscription, plan, quotas, plan feature flags.
///
/// AOID's `ent` claim is a **different system that happens to share the word**:
/// it carries identity and role from `identity_memberships`, and it is what an
/// application maps onto its own roles and permissions. The two are unrelated
/// and must not be conflated in code, comments or tests. Nothing in this file
/// gates identity.
final entitlementsStateProvider =
    NotifierProvider<EntitlementsNotifier, EntitlementsState>(
        EntitlementsNotifier.new);

// ---------------------------------------------------------------------------
// Derived convenience providers
// ---------------------------------------------------------------------------

/// Quick boolean check: can this company use [featureKey]?
///
/// Returns false while loading (deny-by-default).
/// Returns false if the feature is not defined in the plan.
final canUseFeatureProvider = Provider.family<bool, String>((ref, featureKey) {
  final state = ref.watch(entitlementsStateProvider);
  if (state.isLoading) return false;
  final entry = state.entitlements
      .where((e) => e.featureKey == featureKey)
      .firstOrNull;
  return entry?.allowed ?? false;
});

/// Quota details for a feature. Returns null for non-quota or undefined features.
final featureQuotaProvider =
    Provider.family<PlatformEntitlement?, String>((ref, featureKey) {
  final state = ref.watch(entitlementsStateProvider);
  return state.entitlements
      .where((e) => e.featureKey == featureKey && e.isQuota)
      .firstOrNull;
});

/// Feature flag check. Returns false if flag not found or while loading.
final featureFlagProvider = Provider.family<bool, String>((ref, flagKey) {
  final state = ref.watch(entitlementsStateProvider);
  return state.featureFlags
      .where((f) => f.key == flagKey)
      .firstOrNull
      ?.enabled ?? false;
});

/// Current plan (null if no active subscription).
final currentPlanProvider = Provider<PlatformPlan?>((ref) {
  return ref.watch(entitlementsStateProvider).plan;
});

/// Current subscription (null if none).
final currentSubscriptionProvider = Provider<PlatformSubscription?>((ref) {
  return ref.watch(entitlementsStateProvider).subscription;
});
