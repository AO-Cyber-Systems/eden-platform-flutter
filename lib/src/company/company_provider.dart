import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_provider.dart';
import '../constants/storage_keys.dart';
import '../models/platform_models.dart';
import '../platform_config.dart';

class CompanyState {
  final bool isLoading;
  final List<PlatformCompany> companies;
  final PlatformCompany? current;
  final String? errorMessage;

  const CompanyState({
    this.isLoading = false,
    this.companies = const [],
    this.current,
    this.errorMessage,
  });

  CompanyState copyWith({
    bool? isLoading,
    List<PlatformCompany>? companies,
    PlatformCompany? current,
    String? errorMessage,
    bool clearError = false,
  }) {
    return CompanyState(
      isLoading: isLoading ?? this.isLoading,
      companies: companies ?? this.companies,
      current: current ?? this.current,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// The first link after auth in the multi-tenant chain
/// `auth -> company -> currentCompanyProvider -> nav -> entitlements`.
///
/// On riverpod 3's [Notifier]. There is no constructor and no `Ref` field:
/// [Notifier] supplies `ref` as an inherited member, and a shadowing
/// `final Ref ref;` would compile while behaving differently across rebuilds.
class CompanyNotifier extends Notifier<CompanyState> {
  /// Registers the wiring that used to live in the `StateNotifierProvider`
  /// closure, then returns the initial state.
  ///
  /// `NotifierProvider(CompanyNotifier.new)` takes **no closure**, so the
  /// bootstrap and the auth subscription have nowhere else to go. Two ordering
  /// rules apply, and both are pinned by test rather than argued:
  ///
  /// 1. **`ref.listen` is registered BEFORE the microtask is scheduled**, and
  ///    unconditionally. riverpod owns re-registration across rebuilds; an
  ///    "already registered" flag would leak the first subscription and give a
  ///    listener that fires once and then never again.
  /// 2. **The bootstrap stays a microtask.** Calling `loadCompanies` directly
  ///    here would change initialisation ordering, and any helper that reads
  ///    `state` synchronously would throw outright — `state` does not exist
  ///    until `build()` RETURNS (measured at the auth epicentre, 50-21).
  ///
  /// This class keeps no fields outside `state`, so [build] has nothing to
  /// reset. That is not a general licence: a riverpod 3 [Notifier] instance is
  /// REUSED across a rebuild (providers/notifier/orphan.dart:57-60), unlike the
  /// `StateNotifierProvider` this replaced, which ran the constructor afresh
  /// and discarded such fields for free. See doc/riverpod-3-migration.md §3.6.
  @override
  CompanyState build() {
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (!next.isAuthenticated) {
        clear();
        return;
      }
      if (previous?.accessToken != next.accessToken ||
          previous?.companyId != next.companyId) {
        loadCompanies(preferredCompanyId: next.companyId);
      }
    });
    unawaited(Future.microtask(() {
      final auth = ref.read(authProvider);
      if (auth.isAuthenticated) {
        loadCompanies(preferredCompanyId: auth.companyId);
      }
    }));
    return const CompanyState();
  }

  /// Restores notify-on-every-assignment for this provider.
  ///
  /// riverpod 3 filters updates with `==`. [CompanyState] declares no
  /// `operator ==`, so `==` degrades to identity — and [clear] assigns
  /// `const CompanyState()`, which Dart canonicalizes to one object forever.
  /// Clearing a provider that already holds that sentinel is therefore
  /// invisible to listeners.
  ///
  /// MEASURED on this chain, before this migration, with the legacy
  /// `StateNotifier` still in place. Listener fires per link on a sign-out:
  ///
  /// | link | 1st sign-out | 2nd sign-out (already clear) |
  /// |---|---:|---:|
  /// | `authProvider`          | 1 | 1 (50-21 fixed this one) |
  /// | `companyStateProvider`  | 1 | **0** |
  /// | `currentCompanyProvider`| 1 | **0** |
  /// | `navStateProvider`      | 1 | **0** |
  /// | `selectedNavProvider`   | 1 | **0** |
  ///
  /// So this is NOT a riverpod 3 regression and NOT a 50-06 regression:
  /// `StateNotifier.updateShouldNotify` defaults to `!identical(old, current)`,
  /// which for a class with no value `==` is the same predicate riverpod 3
  /// uses. The defect predates the version bump. See §3.8 and §3.10.
  ///
  /// What is lost on a suppressed repeat is the SIGNAL, not the value — the
  /// state is already the cleared sentinel. That still matters, because the
  /// chain's downstream links act on the signal: `entitlements_provider`
  /// clears off it (50-23), and any consumer holding a `ref.listen` on this
  /// provider to drop caches or reset analytics identity never hears it.
  ///
  /// Deliberately scoped to the notifier. Giving [CompanyState] an
  /// `operator ==` would change equality for every consumer in 18+ packages to
  /// fix one notification.
  @override
  bool updateShouldNotify(CompanyState previous, CompanyState next) => true;

  Future<void> loadCompanies({String? preferredCompanyId}) async {
    final auth = ref.read(authProvider);
    final accessToken = auth.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      state = const CompanyState();
      return;
    }

    // In B2C mode, use the personal workspace from JWT silently —
    // no API call, empty companies list so CompanySwitcher is hidden.
    final config = ref.read(platformConfigProvider);
    if (config.isB2C && auth.companyId != null) {
      state = CompanyState(
        companies: const [], // empty = CompanySwitcher hidden
        current: PlatformCompany(
          id: auth.companyId!,
          name: auth.user?.displayName ?? '',
          slug: 'personal',
          companyType: 'personal',
        ),
      );
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final companies =
          await ref.read(platformRepositoryProvider).listCompanies(accessToken);
      final prefs = await SharedPreferences.getInstance();
      final storedCompanyId = prefs.getString(StorageKeys.kCurrentCompanyId);
      final selected = _selectCompany(
        companies,
        preferredCompanyId: preferredCompanyId,
        storedCompanyId: storedCompanyId,
      );

      if (selected != null) {
        await prefs.setString(StorageKeys.kCurrentCompanyId, selected.id);
      }

      // Post-await guard. Reading OR writing `state` on a disposed element
      // throws `Bad state: Tried to use CompanyNotifier after 'dispose' was
      // called`. riverpod 3 tears an element down whenever it goes unlistened
      // (the pause rule, §3.2.1), so a container disposed or a consumer
      // unmounted mid-load reaches here on a dead notifier.
      if (!ref.mounted) return;
      state = CompanyState(
        companies: companies,
        current: selected,
      );
    } catch (error) {
      if (!ref.mounted) return;
      state = CompanyState(
        companies: state.companies,
        current: state.current,
        errorMessage: error.toString(),
      );
    }
  }

  Future<void> setCompany(PlatformCompany company) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.kCurrentCompanyId, company.id);
    if (!ref.mounted) return;
    state = state.copyWith(current: company, clearError: true);
  }

  void clear() {
    state = const CompanyState();
  }

  PlatformCompany? _selectCompany(
    List<PlatformCompany> companies, {
    String? preferredCompanyId,
    String? storedCompanyId,
  }) {
    for (final candidateId in [preferredCompanyId, storedCompanyId]) {
      if (candidateId == null || candidateId.isEmpty) {
        continue;
      }
      for (final company in companies) {
        if (company.id == candidateId) {
          return company;
        }
      }
    }
    return companies.isEmpty ? null : companies.first;
  }
}

// The provider closure is gone: `NotifierProvider` takes a zero-argument
// notifier factory, not a create callback. The bootstrap microtask and the auth
// subscription that used to live here are now in `CompanyNotifier.build()`.
// Signature from the RESOLVED package — riverpod 3.3.2,
// lib/src/providers/notifier/orphan.dart:78-94. `isAutoDispose` defaults to
// false, preserving the keep-alive lifetime StateNotifierProvider had.
final companyStateProvider =
    NotifierProvider<CompanyNotifier, CompanyState>(CompanyNotifier.new);

final currentCompanyProvider = Provider<PlatformCompany?>((ref) {
  return ref.watch(companyStateProvider).current;
});

final companiesProvider = Provider<List<PlatformCompany>>((ref) {
  return ref.watch(companyStateProvider).companies;
});
