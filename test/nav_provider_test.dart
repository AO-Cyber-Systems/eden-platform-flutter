import 'dart:async';
import 'dart:io';

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
  ///
  /// STILL REQUIRED after the Notifier migration. §3.2.2 measured
  /// a faithful `Notifier` mirror breaking identically under a one-shot
  /// `container.read` — `NotifierProvider` goes through the same
  /// `ProviderElement.onCancel()` deactivation, so the migration is orthogonal
  /// to the pause rule. Removing this helper re-breaks the same six tests.
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

  // =====================================================================
  // Stage B: the provider-closure -> Notifier.build() port.
  // =====================================================================

  group('the currentCompanyProvider listener', () {
    test('a company id CHANGE reloads nav for the new company', () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession(companyId: 'c1')
        ..listCompaniesResult = [buildCompany(id: 'c1'), buildCompany(id: 'c2')]
        ..listNavItemsResult = [buildNavItem(id: 'n1')];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      subscribeNav(container);
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(container.read(currentCompanyProvider)?.id, 'c1',
          reason: 'premise: nav is loaded for c1 before the switch');
      final callsBefore = repository.listNavItemsCalls;
      repository.listNavItemsResult = [
        buildNavItem(id: 'n2-a'),
        buildNavItem(id: 'n2-b'),
      ];

      await container
          .read(companyStateProvider.notifier)
          .setCompany(buildCompany(id: 'c2'));
      await deepSettle();

      expect(repository.listNavItemsCalls - callsBefore, 1,
          reason: 'exactly one reload for the new company');
      expect(container.read(navStateProvider).items.length, 2);
      expect(container.read(navItemsProvider).length, 2,
          reason: 'the derived navItemsProvider must track it');
    });

    test('the same company id re-set does NOT reload', () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession(companyId: 'c1')
        ..listCompaniesResult = [buildCompany(id: 'c1')]
        ..listNavItemsResult = [buildNavItem(id: 'n1')];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      subscribeNav(container);
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      final callsBefore = repository.listNavItemsCalls;
      expect(callsBefore, greaterThan(0),
          reason: 'premise: nav loaded at least once, so a second load would '
              'be visible');

      await container
          .read(companyStateProvider.notifier)
          .setCompany(buildCompany(id: 'c1'));
      await deepSettle();

      expect(repository.listNavItemsCalls, callsBefore,
          reason: '`previous?.id != next.id` must gate the reload');
    });
  });

  group('loadForCompany error branch', () {
    test('a failure PRESERVES the items already loaded and surfaces '
        'errorMessage', () async {
      // The pre-existing "items preserved" test asserted only errorMessage,
      // against a fixture where nav had never loaded anything — so "preserved"
      // was vacuously true and a branch that wiped the items would have
      // passed. This drives a SUCCESSFUL load first, so there is something to
      // lose.
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession(companyId: 'c1')
        ..listCompaniesResult = [buildCompany(id: 'c1'), buildCompany(id: 'c2')]
        ..listNavItemsResult = [
          buildNavItem(id: 'keep-1'),
          buildNavItem(id: 'keep-2'),
        ];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      subscribeNav(container);
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(container.read(navStateProvider).items.length, 2,
          reason: 'premise: there are items to preserve');
      expect(container.read(navStateProvider).selectedId, 'keep-1');

      repository.listNavItemsError = Exception('Nav API error');
      await container.read(navStateProvider.notifier).loadForCompany('c2');
      await deepSettle();

      final state = container.read(navStateProvider);
      expect(state.errorMessage, contains('Nav API error'));
      expect(state.items.map((i) => i.id), ['keep-1', 'keep-2'],
          reason: 'a failed reload must not wipe the visible navigation');
      expect(state.selectedId, 'keep-1');
      expect(state.isLoading, false);
    });
  });

  group('post-await disposal guards (the crash deferred by §3.2.4)', () {
    test('a load that resolves AFTER disposal does not throw — SUCCESS path',
        () async {
      SharedPreferences.setMockInitialValues({});
      final gate = Completer<List<PlatformNavItem>>();
      final repo = _GatedNavRepository(gate);
      repo
        ..loginResult = buildSession(companyId: 'c1')
        ..listCompaniesResult = [buildCompany(id: 'c1')];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repo)],
      );
      subscribeNav(container);
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(repo.listNavItemsCalls, 1,
          reason: 'premise: a load is genuinely in flight');
      expect(gate.isCompleted, false);

      container.dispose();
      gate.complete([buildNavItem()]);
      // Unguarded this throws "Bad state: Tried to use NavNotifier after
      // 'dispose' was called" as an unhandled async error out of the settle.
      await deepSettle();
    });

    test('a load that FAILS after disposal does not throw — CATCH path',
        () async {
      // The catch path is the one the crash actually surfaced through
      // (nav_provider.dart:66 pre-port): a disposal mid-await makes the try
      // body throw, and the recovery assignment then throws again from inside
      // the handler, where nothing can catch it.
      SharedPreferences.setMockInitialValues({});
      final gate = Completer<List<PlatformNavItem>>();
      final repo = _GatedNavRepository(gate);
      repo
        ..loginResult = buildSession(companyId: 'c1')
        ..listCompaniesResult = [buildCompany(id: 'c1')];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repo)],
      );
      subscribeNav(container);
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(repo.listNavItemsCalls, 1);
      expect(gate.isCompleted, false);

      container.dispose();
      gate.completeError(Exception('nav fetch failed after disposal'));
      await deepSettle();
    });

    test('CONTROL: the same gated flow UNDISPOSED really does write the state',
        () async {
      // Without this, both assertions above would pass just as happily if the
      // load never ran or the gate never resolved.
      SharedPreferences.setMockInitialValues({});
      final gate = Completer<List<PlatformNavItem>>();
      final repo = _GatedNavRepository(gate);
      repo
        ..loginResult = buildSession(companyId: 'c1')
        ..listCompaniesResult = [buildCompany(id: 'c1')];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      subscribeNav(container);
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(container.read(navStateProvider).items, isEmpty,
          reason: 'premise: nothing written while the load is parked');

      gate.complete([buildNavItem(id: 'arrived')]);
      await deepSettle();

      expect(container.read(navStateProvider).items.single.id, 'arrived');
      expect(container.read(navStateProvider).selectedId, 'arrived');
    });
  });

  // =====================================================================
  // The multi-tenant isolation assertion (the spec test 7).
  //
  // These providers are two links in
  //   auth -> company -> currentCompanyProvider -> nav -> entitlements
  // Every link is asserted, not just the ends: a broken middle looks like a
  // passing test if only the endpoints are checked.
  // =====================================================================
  group('logout chain', () {
    test('a sign-out clears EVERY link, and a repeat sign-out still notifies '
        'the notifier links despite the const sentinel', () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession(companyId: 'c1')
        ..listCompaniesResult = [buildCompany(id: 'c1'), buildCompany(id: 'c2')]
        ..listNavItemsResult = [
          buildNavItem(id: 'n1'),
          buildNavItem(id: 'n2'),
        ];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      final companyFires = <int>[];
      final currentCompanyFires = <String?>[];
      final companiesFires = <int>[];
      final navFires = <int>[];
      final navItemsFires = <int>[];
      final selectedNavFires = <String?>[];

      container.listen<CompanyState>(
          companyStateProvider, (_, n) => companyFires.add(n.companies.length));
      container.listen<PlatformCompany?>(
          currentCompanyProvider, (_, n) => currentCompanyFires.add(n?.id));
      container.listen<List<PlatformCompany>>(
          companiesProvider, (_, n) => companiesFires.add(n.length));
      container.listen<NavState>(
          navStateProvider, (_, n) => navFires.add(n.items.length));
      container.listen<List<PlatformNavItem>>(
          navItemsProvider, (_, n) => navItemsFires.add(n.length));
      container.listen<String?>(
          selectedNavProvider, (_, n) => selectedNavFires.add(n));

      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      // ---- PREMISE. Every link must be POPULATED, or the "is empty"
      // assertions below are vacuously true and this test proves nothing.
      // The nil-fixture trap is precisely what a logout test invites.
      expect(container.read(companyStateProvider).companies, isNotEmpty);
      expect(container.read(companyStateProvider).current, isNotNull);
      expect(container.read(currentCompanyProvider), isNotNull);
      expect(container.read(companiesProvider), isNotEmpty);
      expect(container.read(navStateProvider).items, isNotEmpty);
      expect(container.read(navStateProvider).selectedId, isNotNull);
      expect(container.read(navItemsProvider), isNotEmpty);
      expect(container.read(selectedNavProvider), isNotNull);

      companyFires.clear();
      currentCompanyFires.clear();
      companiesFires.clear();
      navFires.clear();
      navItemsFires.clear();
      selectedNavFires.clear();

      // ---- FIRST sign-out: every link must both NOTIFY and CLEAR.
      await container.read(authProvider.notifier).logout();
      await deepSettle();

      expect(companyFires, isNotEmpty, reason: 'link 1: companyStateProvider');
      expect(currentCompanyFires, isNotEmpty,
          reason: 'link 2: currentCompanyProvider — the derived middle link '
              'whose silence would strand nav on the previous tenant');
      expect(companiesFires, isNotEmpty, reason: 'link 2b: companiesProvider');
      expect(navFires, isNotEmpty, reason: 'link 3: navStateProvider');
      expect(navItemsFires, isNotEmpty, reason: 'link 3b: navItemsProvider');
      expect(selectedNavFires, isNotEmpty, reason: 'link 3c: selectedNavProvider');

      expect(container.read(companyStateProvider).companies, isEmpty);
      expect(container.read(companyStateProvider).current, isNull);
      expect(container.read(currentCompanyProvider), isNull);
      expect(container.read(companiesProvider), isEmpty);
      expect(container.read(navStateProvider).items, isEmpty);
      expect(container.read(navStateProvider).selectedId, isNull);
      expect(container.read(navItemsProvider), isEmpty);
      expect(container.read(selectedNavProvider), isNull);

      // ---- SECOND-ORDER CASE. `clear()` assigns `const CompanyState()` /
      // `const NavState()`, which Dart canonicalizes to ONE object. riverpod 3
      // filters updates with `==`, and these classes declare no `operator ==`,
      // so `==` degrades to identity: re-assigning the sentinel a provider
      // already holds is invisible. That drops the clear AFTER the sign-out
      // has already propagated, not merely on a repeat login/logout pair.
      //
      // MEASURED before this migration, with StateNotifier still in place:
      // company 0, currentCompany 0, nav 0, selectedNav 0 fires on the second
      // sign-out. The defect predates the riverpod bump — StateNotifier's own
      // `!identical` default is the same predicate. See §3.8 / §3.10.
      companyFires.clear();
      currentCompanyFires.clear();
      companiesFires.clear();
      navFires.clear();
      navItemsFires.clear();
      selectedNavFires.clear();

      await container.read(authProvider.notifier).logout();
      await deepSettle();

      expect(companyFires, isNotEmpty,
          reason: 'the second clear must still notify — restored by '
              'CompanyNotifier.updateShouldNotify');
      expect(navFires, isNotEmpty,
          reason: 'the second clear must still notify — restored by '
              'NavNotifier.updateShouldNotify');

      // The DERIVED links legitimately stay silent here, and that is not a
      // bug to be "fixed": a plain `Provider` runs its own
      // `previous != next` filter (riverpod-3.3.2 providers/provider.dart:349)
      // and null -> null is genuinely not a change. `updateShouldNotify` on
      // the upstream notifier does NOT punch through it. Asserted explicitly
      // so a later reader does not chase it, and so that nav's independence
      // from the company route on sign-out stays visible.
      expect(currentCompanyFires, isEmpty);
      expect(selectedNavFires, isEmpty);

      //...and everything is still clear.
      expect(container.read(companyStateProvider).companies, isEmpty);
      expect(container.read(currentCompanyProvider), isNull);
      expect(container.read(navStateProvider).items, isEmpty);
      expect(container.read(selectedNavProvider), isNull);
    });

    test('PREMISE GUARDS for the test above: the sentinels really are '
        'canonicalized and the state classes really have no value ==', () {
      // If either premise ever stops holding, the second-order test above
      // would pass for the wrong reason. Dart canonicalizes const instances...
      expect(identical(const NavState(), const NavState()), true);
      expect(identical(const CompanyState(), const CompanyState()), true);
      //...and these classes declare no `operator ==`, so two structurally
      // identical NON-const instances compare unequal. That is what makes
      // riverpod 3's `previous != next` degrade to an identity test, and what
      // makes it coincide with StateNotifier's `!identical` default.
      expect(NavState() == NavState(), false);
      expect(CompanyState() == CompanyState(), false);
    });

    test('a const-sentinel assignment from a path OTHER than clear() also '
        'notifies', () async {
      // `clear()` is not the only place these notifiers assign the
      // canonicalized sentinel: `loadForCompany`'s no-token early return does
      // `state = const NavState()` too, and so does `loadCompanies`'s. A
      // remedy that only de-consts `clear()` would leave those paths
      // suppressed — measured: that mutation survives every other test here.
      // This is what pins the fix to `updateShouldNotify` on the notifier
      // rather than to the shape of one assignment.
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession(companyId: 'c1')
        ..listCompaniesResult = [buildCompany(id: 'c1')]
        ..listNavItemsResult = [buildNavItem(id: 'n1')];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final navFires = <int>[];
      final companyFires = <int>[];
      container.listen<NavState>(
          navStateProvider, (_, n) => navFires.add(n.items.length));
      container.listen<CompanyState>(
          companyStateProvider, (_, n) => companyFires.add(n.companies.length));
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();
      await container.read(authProvider.notifier).logout();
      await deepSettle();

      // PREMISE: both providers are now sitting on the const sentinel, so the
      // assignments below are sentinel-to-sentinel — the case that is dropped
      // under the default filter.
      expect(container.read(navStateProvider).items, isEmpty);
      expect(container.read(companyStateProvider).companies, isEmpty);
      expect(container.read(authProvider).accessToken, isNull,
          reason: 'premise: the no-token early return is the path taken');

      // Drive the no-token early return ONCE first. After this the provider is
      // holding the canonicalized sentinel that the early return itself
      // produced — which is the state a de-consted `clear()` cannot arrange.
      await container.read(navStateProvider.notifier).loadForCompany('c1');
      await container.read(companyStateProvider.notifier).loadCompanies();
      await deepSettle();

      navFires.clear();
      companyFires.clear();

      //...and again. THIS is the sentinel-to-identical-sentinel assignment,
      // and it comes from the early return, not from clear(). Only a remedy
      // that covers the whole notifier — `updateShouldNotify` — makes it
      // notify. De-consting `clear()` leaves this path suppressed, which is a
      // silent PARTIAL fix; measured, that mutation survives every other test
      // in this file.
      await container.read(navStateProvider.notifier).loadForCompany('c1');
      await container.read(companyStateProvider.notifier).loadCompanies();
      await deepSettle();

      expect(navFires, isNotEmpty,
          reason: 'loadForCompany\'s no-token `state = const NavState()` must '
              'still notify when the provider already holds that sentinel');
      expect(companyFires, isNotEmpty,
          reason: 'loadCompanies\'s no-token `state = const CompanyState()` '
              'must still notify when the provider already holds that '
              'sentinel');
    });

    test('nav clears on sign-out even when the company route is silent — the '
        'auth listener is an independent second route', () async {
      // The chain diagram suggests nav depends on company for its clear. It
      // does not: nav listens to authProvider directly as well. This matters
      // because the company -> currentCompanyProvider hop can legitimately go
      // quiet (null -> null is filtered by the derived Provider), and without
      // the direct route nav would then keep the previous tenant's items.
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession(companyId: 'c1')
        ..listCompaniesResult = [buildCompany(id: 'c1')]
        ..listNavItemsResult = [buildNavItem(id: 'n1')];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      subscribeNav(container);
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      // Put company at the const sentinel FIRST, so the sign-out's own
      // company.clear() is a sentinel-to-sentinel assignment and the derived
      // currentCompanyProvider cannot change (null -> null). Then re-populate
      // nav directly, so there IS something for the sign-out to clear.
      container.read(companyStateProvider.notifier).clear();
      await deepSettle();
      await container.read(navStateProvider.notifier).loadForCompany('c1');
      await deepSettle();

      expect(container.read(currentCompanyProvider), isNull,
          reason: 'premise: the company route is already at the sentinel');
      expect(container.read(navStateProvider).items, isNotEmpty,
          reason: 'premise: nav holds the previous tenant\'s items');

      await container.read(authProvider.notifier).logout();
      await deepSettle();

      expect(container.read(navStateProvider).items, isEmpty,
          reason: 'the direct auth listener must clear nav even with the '
              'company route silent');
      expect(container.read(selectedNavProvider), isNull);
    });
  });

  group('source: Stage A is finished for this file', () {
    test('nav_provider.dart is on Notifier, has no Ref field, keeps both '
        'listeners and guards both post-await paths', () {
      final src =
          File('lib/src/navigation/nav_provider.dart').readAsStringSync();
      expect(src.length, greaterThan(2000),
          reason: 'the file must actually have been read');

      final code = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.contains('class NavNotifier extends Notifier<NavState>'), true,
          reason: 'comment-stripping must not remove the declaration');
      expect(code.length, lessThan(src.length),
          reason: 'comment-stripping must actually have removed something');

      final banned = ['State', 'Notifier'].join();
      expect(code.contains(banned), false);
      final legacyImport = "flutter_riverpod/${'legacy'}.dart";
      expect(src.contains("import 'package:$legacyImport'"), false);

      expect(RegExp(r'final\s+Ref\s+ref\s*;').hasMatch(code), false);
      expect(code.contains('NavNotifier(this.ref)'), false);

      // TWO subscriptions here, not one, plus the single bootstrap.
      expect('ref.listen'.allMatches(code).length, 2);
      expect('Future.microtask'.allMatches(code).length, 1);
      expect(code.indexOf('ref.listen'),
          lessThan(code.indexOf('Future.microtask')),
          reason: 'listeners registered before the bootstrap is scheduled');

      // Both post-await guards in loadForCompany. The behaviour tests above
      // are the real proof; this catches a silent deletion of one of the two.
      final loadBody = code.substring(
        code.indexOf('Future<void> loadForCompany'),
        code.indexOf('void select('),
      );
      expect('if (!ref.mounted) return;'.allMatches(loadBody).length, 2,
          reason: 'success path AND catch path');

      expect(code.contains('final navItemsProvider = Provider<List<PlatformNavItem>>'),
          true);
      expect(code.contains('final selectedNavProvider = Provider<String?>'), true);
      expect(
          code.contains('NotifierProvider<NavNotifier, NavState>(NavNotifier.new)'),
          true);
      expect(code.contains('operator =='), false);
    });
  });
}

/// [PlatformRepository] whose `listNavItems` parks on a [Completer], so a test
/// can dispose the container mid-await. `FakePlatformRepository` resolves
/// immediately, which cannot exercise a disposal that happens DURING the await.
class _GatedNavRepository extends FakePlatformRepository {
  _GatedNavRepository(this._gate);

  final Completer<List<PlatformNavItem>> _gate;

  @override
  Future<List<PlatformNavItem>> listNavItems(
      String accessToken, String companyId) {
    listNavItemsCalls++;
    return _gate.future;
  }
}
