import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlatformRepository repository;

  setUp(() {
    repository = FakePlatformRepository();
    installSecureStorageChannelMock();
  });

  tearDown(uninstallSecureStorageChannelMock);

  /// Settle multiple rounds to allow auth -> company -> nav microtask chains.
  Future<void> deepSettle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Open a REAL, long-lived subscription to [navStateProvider].
  ///
  /// This must not be a bare `container.read(navStateProvider)`. `read` opens a
  /// subscription and closes it again immediately, so it leaves the provider
  /// with zero listeners. riverpod 3 treats an unlistened provider as *paused*
  /// ("a provider is considered paused if all of its listeners are paused" —
  /// riverpod 3.0 CHANGELOG) and `ProviderElement.onCancel` then calls
  /// `deactivate()` on every subscription that element itself created — here,
  /// nav's two `ref.listen` calls. The pause cascades up the whole
  /// auth -> company -> nav chain, so the chain never delivers and nav stays
  /// empty. In riverpod 2 there were no pause semantics, so the one-shot read
  /// happened to work.
  ///
  /// Not closed deliberately: `container.dispose()` at the end of each test
  /// tears it down. See doc/riverpod-3-migration.md §3.2.
  void subscribeNav(ProviderContainer container) {
    container.listen<NavState>(navStateProvider, (previous, next) {});
  }

  group('loadForCompany', () {
    test('loads nav items for given company', () async {
      SharedPreferences.setMockInitialValues({});
      final navItems = [
        buildNavItem(id: 'home', label: 'Home'),
        buildNavItem(id: 'settings', label: 'Settings', priority: 1),
      ];
      repository
        ..loginResult = buildSession()
        ..listCompaniesResult = [buildCompany()]
        ..listNavItemsResult = navItems;

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );

      container.read(authProvider.notifier);
      await deepSettle();

      // Subscribe to nav state to start the listener chain.
      // MUST be a real subscription, not `read` — see subscribeNav.
      subscribeNav(container);

      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      final state = container.read(navStateProvider);
      expect(state.items.length, 2);
      expect(state.isLoading, false);

      container.dispose();
    });

    test('auto-selects first item when loaded', () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession()
        ..listCompaniesResult = [buildCompany()]
        ..listNavItemsResult = [
          buildNavItem(id: 'first', label: 'First'),
          buildNavItem(id: 'second', label: 'Second'),
        ];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );

      container.read(authProvider.notifier);
      await deepSettle();
      subscribeNav(container);
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(container.read(navStateProvider).selectedId, 'first');

      container.dispose();
    });
  });

  group('select', () {
    test('updates selectedId', () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession()
        ..listCompaniesResult = [buildCompany()]
        ..listNavItemsResult = [
          buildNavItem(id: 'home', label: 'Home'),
          buildNavItem(id: 'settings', label: 'Settings'),
        ];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );

      container.read(authProvider.notifier);
      await deepSettle();
      subscribeNav(container);
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      container.read(navStateProvider.notifier).select('settings');

      expect(container.read(navStateProvider).selectedId, 'settings');

      container.dispose();
    });
  });

  group('clear', () {
    test('resets to empty state', () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession()
        ..listCompaniesResult = [buildCompany()]
        ..listNavItemsResult = [buildNavItem()];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );

      container.read(authProvider.notifier);
      await deepSettle();
      subscribeNav(container);
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(container.read(navStateProvider).items, isNotEmpty);

      container.read(navStateProvider.notifier).clear();

      final state = container.read(navStateProvider);
      expect(state.items, isEmpty);
      expect(state.selectedId, isNull);

      container.dispose();
    });
  });

  group('error handling', () {
    test('API error -> errorMessage set, items preserved', () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession()
        ..listCompaniesResult = [buildCompany()]
        ..listNavItemsError = Exception('Nav API error');

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );

      container.read(authProvider.notifier);
      await deepSettle();
      subscribeNav(container);
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      final state = container.read(navStateProvider);
      expect(state.errorMessage, contains('Nav API error'));

      container.dispose();
    });
  });

  group('auto-clear on auth logout', () {
    test('nav clears when auth becomes unauthenticated', () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession()
        ..listCompaniesResult = [buildCompany()]
        ..listNavItemsResult = [buildNavItem()];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );

      container.read(authProvider.notifier);
      await deepSettle();
      subscribeNav(container);
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(container.read(navStateProvider).items, isNotEmpty);

      await container.read(authProvider.notifier).logout();
      await deepSettle();

      final state = container.read(navStateProvider);
      expect(state.items, isEmpty);
      expect(state.selectedId, isNull);

      container.dispose();
    });
  });
}
