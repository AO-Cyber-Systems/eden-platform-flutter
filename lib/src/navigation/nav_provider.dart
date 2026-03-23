import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_provider.dart';
import '../company/company_provider.dart';
import '../models/platform_models.dart';

class NavState {
  final bool isLoading;
  final List<PlatformNavItem> items;
  final String? selectedId;
  final String? errorMessage;

  const NavState({
    this.isLoading = false,
    this.items = const [],
    this.selectedId,
    this.errorMessage,
  });

  NavState copyWith({
    bool? isLoading,
    List<PlatformNavItem>? items,
    String? selectedId,
    String? errorMessage,
    bool clearError = false,
  }) {
    return NavState(
      isLoading: isLoading ?? this.isLoading,
      items: items ?? this.items,
      selectedId: selectedId ?? this.selectedId,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class NavNotifier extends StateNotifier<NavState> {
  NavNotifier(this.ref) : super(const NavState());

  final Ref ref;

  Future<void> loadForCompany(String companyId) async {
    final accessToken = ref.read(authProvider).accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      state = const NavState();
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final items = await ref
          .read(platformRepositoryProvider)
          .listNavItems(accessToken, companyId);
      state = NavState(
        items: items,
        selectedId: items.isEmpty ? null : (state.selectedId ?? items.first.id),
      );
    } catch (error) {
      state = NavState(
        items: state.items,
        selectedId: state.selectedId,
        errorMessage: error.toString(),
      );
    }
  }

  void select(String id) {
    state = state.copyWith(selectedId: id, clearError: true);
  }

  void clear() {
    state = const NavState();
  }
}

final navStateProvider = StateNotifierProvider<NavNotifier, NavState>((ref) {
  final notifier = NavNotifier(ref);
  Future.microtask(() {
    final auth = ref.read(authProvider);
    final company = ref.read(currentCompanyProvider);
    if (auth.isAuthenticated && company != null) {
      notifier.loadForCompany(company.id);
    }
  });
  ref.listen<AuthState>(authProvider, (previous, next) {
    if (!next.isAuthenticated) {
      notifier.clear();
    }
  });
  ref.listen<PlatformCompany?>(currentCompanyProvider, (previous, next) {
    if (next == null) {
      notifier.clear();
      return;
    }
    if (previous?.id != next.id) {
      notifier.loadForCompany(next.id);
    }
  });
  return notifier;
});

final navItemsProvider = Provider<List<PlatformNavItem>>((ref) {
  return ref.watch(navStateProvider).items;
});

final selectedNavProvider = Provider<String?>((ref) {
  return ref.watch(navStateProvider).selectedId;
});
