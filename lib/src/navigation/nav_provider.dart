import 'dart:async';

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

/// The link after `currentCompanyProvider` in the multi-tenant chain
/// `auth -> company -> currentCompanyProvider -> nav -> entitlements`.
///
/// On riverpod 3's [Notifier]. No constructor, no `Ref` field: [Notifier]
/// supplies `ref`, and a shadowing `final Ref ref;` would compile while
/// behaving differently across rebuilds.
class NavNotifier extends Notifier<NavState> {
  /// Registers BOTH subscriptions and the bootstrap, then returns the initial
  /// state. See [CompanyNotifier.build] for the two ordering rules; this class
  /// has two `ref.listen` calls rather than one.
  ///
  /// Note the second listener targets [currentCompanyProvider] — a derived
  /// plain `Provider`, unaffected by this migration — not
  /// [companyStateProvider]. Its target is unchanged, but it only fires if
  /// `companyStateProvider` notified AND the derived value actually changed:
  /// a plain `Provider` runs its own `previous != next` filter
  /// (riverpod-3.3.2 lib/src/providers/provider.dart:349), which
  /// `updateShouldNotify` on the upstream notifier does NOT punch through.
  /// That is why nav's sign-out clear hangs off the `authProvider` listener
  /// directly and not only off the company path — two independent routes, and
  /// the isolation tests assert both.
  @override
  NavState build() {
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (!next.isAuthenticated) {
        clear();
      }
    });
    ref.listen<PlatformCompany?>(currentCompanyProvider, (previous, next) {
      if (next == null) {
        clear();
        return;
      }
      if (previous?.id != next.id) {
        loadForCompany(next.id);
      }
    });
    unawaited(Future.microtask(() {
      final auth = ref.read(authProvider);
      final company = ref.read(currentCompanyProvider);
      if (auth.isAuthenticated && company != null) {
        loadForCompany(company.id);
      }
    }));
    return const NavState();
  }

  /// Restores notify-on-every-assignment. Same cause, same measurement and the
  /// same deliberate scoping as [CompanyNotifier.updateShouldNotify]: [NavState]
  /// has no `operator ==`, [clear] assigns the canonicalized
  /// `const NavState()`, and a repeat clear is otherwise invisible. Measured 0
  /// fires on a second sign-out before this migration, under `StateNotifier`.
  @override
  bool updateShouldNotify(NavState previous, NavState next) => true;

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
      // Post-await guard on the SUCCESS path.
      //
      // This is the crash doc/riverpod-3-migration.md §3.2.4 deferred, and it
      // is latent in production today for any consumer that lets
      // nav go unlistened mid-load: riverpod 3 pauses and tears down an
      // element with no listeners (§3.2.1), and the assignment below then
      // throws `Bad state: Tried to use NavNotifier after 'dispose' was
      // called`. It was withheld from that gap-closure to keep it minimal.
      //
      // The guard must precede the WHOLE assignment, not just the write: the
      // arguments read `state.selectedId`, and reading a disposed element
      // throws too.
      if (!ref.mounted) return;
      state = NavState(
        items: items,
        selectedId: items.isEmpty ? null : (state.selectedId ?? items.first.id),
      );
    } catch (error) {
      // Post-await guard on the CATCH path. This is the one the crash actually
      // surfaced through: a disposal that happens mid-await makes the try body
      // throw, and the recovery assignment then throws again from the handler.
      if (!ref.mounted) return;
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

// The provider closure is gone; both subscriptions and the bootstrap live in
// `NavNotifier.build()`. Signature from the RESOLVED package — riverpod 3.3.2,
// lib/src/providers/notifier/orphan.dart:78-94. Keep-alive, as before.
final navStateProvider =
    NotifierProvider<NavNotifier, NavState>(NavNotifier.new);

final navItemsProvider = Provider<List<PlatformNavItem>>((ref) {
  return ref.watch(navStateProvider).items;
});

final selectedNavProvider = Provider<String?>((ref) {
  return ref.watch(navStateProvider).selectedId;
});
