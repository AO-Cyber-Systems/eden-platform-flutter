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

class EntitlementsNotifier extends StateNotifier<EntitlementsState> {
  EntitlementsNotifier(this.ref) : super(const EntitlementsState());

  final Ref ref;

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

final entitlementsStateProvider =
    StateNotifierProvider<EntitlementsNotifier, EntitlementsState>((ref) {
  final notifier = EntitlementsNotifier(ref);

  // Auto-load when auth and company are available
  Future.microtask(() {
    final auth = ref.read(authProvider);
    final company = ref.read(currentCompanyProvider);
    if (auth.isAuthenticated && company != null) {
      notifier.load(company.id);
    }
  });

  // Clear on logout
  ref.listen<AuthState>(authProvider, (previous, next) {
    if (!next.isAuthenticated) {
      notifier.clear();
    }
  });

  // Reload on company switch
  ref.listen<PlatformCompany?>(currentCompanyProvider, (previous, next) {
    if (next == null) {
      notifier.clear();
      return;
    }
    if (previous?.id != next.id) {
      notifier.load(next.id);
    }
  });

  return notifier;
});

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
