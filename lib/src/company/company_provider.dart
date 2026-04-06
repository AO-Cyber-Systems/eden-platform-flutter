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

class CompanyNotifier extends StateNotifier<CompanyState> {
  CompanyNotifier(this.ref) : super(const CompanyState());

  final Ref ref;

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

      state = CompanyState(
        companies: companies,
        current: selected,
      );
    } catch (error) {
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

final companyStateProvider =
    StateNotifierProvider<CompanyNotifier, CompanyState>((ref) {
  final notifier = CompanyNotifier(ref);
  Future.microtask(() {
    final auth = ref.read(authProvider);
    if (auth.isAuthenticated) {
      notifier.loadCompanies(preferredCompanyId: auth.companyId);
    }
  });
  ref.listen<AuthState>(authProvider, (previous, next) {
    if (!next.isAuthenticated) {
      notifier.clear();
      return;
    }
    if (previous?.accessToken != next.accessToken ||
        previous?.companyId != next.companyId) {
      notifier.loadCompanies(preferredCompanyId: next.companyId);
    }
  });
  return notifier;
});

final currentCompanyProvider = Provider<PlatformCompany?>((ref) {
  return ref.watch(companyStateProvider).current;
});

final companiesProvider = Provider<List<PlatformCompany>>((ref) {
  return ref.watch(companyStateProvider).companies;
});
