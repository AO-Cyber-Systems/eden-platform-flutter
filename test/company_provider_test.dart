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
    // SecureTokenStorage (default backing for AuthNotifier in TRD 10-03)
    // calls flutter_secure_storage which has no native side in unit tests —
    // install a MethodChannel mock to avoid MissingPluginException.
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

  group('loadCompanies', () {
    test('loads companies when authenticated', () async {
      SharedPreferences.setMockInitialValues({});
      final companies = [
        buildCompany(id: 'c1', name: 'Company A'),
        buildCompany(id: 'c2', name: 'Company B'),
      ];
      repository
        ..loginResult = buildSession()
        ..listCompaniesResult = companies;

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );

      // Read auth to start restore session
      container.read(authProvider.notifier);
      await deepSettle();

      // Subscribe to company state
      container.read(companyStateProvider);

      // Login triggers company auto-load via listener
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      final state = container.read(companyStateProvider);
      expect(state.companies.length, 2);
      expect(state.current, isNotNull);
      expect(state.isLoading, false);

      container.dispose();
    });

    test('returns empty when not authenticated', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );

      container.read(authProvider.notifier);
      await deepSettle();

      // Auth is unauthenticated — company should be empty
      container.read(companyStateProvider);
      await deepSettle();

      expect(container.read(companyStateProvider).companies, isEmpty);
      expect(container.read(companyStateProvider).current, isNull);

      container.dispose();
    });

    test('selects stored company from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        'current_company_id': 'c2',
      });
      final companies = [
        buildCompany(id: 'c1', name: 'First'),
        buildCompany(id: 'c2', name: 'Second'),
      ];
      repository
        ..loginResult = buildSession(companyId: null)
        ..listCompaniesResult = companies;

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );

      container.read(authProvider.notifier);
      await deepSettle();
      container.read(companyStateProvider);
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      final state = container.read(companyStateProvider);
      expect(state.current?.id, 'c2');

      container.dispose();
    });

    test('falls back to first company when no preference', () async {
      SharedPreferences.setMockInitialValues({});
      final companies = [
        buildCompany(id: 'c1', name: 'First'),
        buildCompany(id: 'c2', name: 'Second'),
      ];
      repository
        ..loginResult = buildSession(companyId: null)
        ..listCompaniesResult = companies;

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );

      container.read(authProvider.notifier);
      await deepSettle();
      container.read(companyStateProvider);
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(container.read(companyStateProvider).current?.id, 'c1');

      container.dispose();
    });

    test('selects preferred company from auth session', () async {
      SharedPreferences.setMockInitialValues({});
      final companies = [
        buildCompany(id: 'c1', name: 'First'),
        buildCompany(id: 'c2', name: 'Second'),
      ];
      repository
        ..loginResult = buildSession(companyId: 'c2')
        ..listCompaniesResult = companies;

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );

      container.read(authProvider.notifier);
      await deepSettle();
      container.read(companyStateProvider);
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(container.read(companyStateProvider).current?.id, 'c2');

      container.dispose();
    });
  });

  group('setCompany', () {
    test('switches current company + persists to SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final companies = [
        buildCompany(id: 'c1', name: 'First'),
        buildCompany(id: 'c2', name: 'Second'),
      ];
      repository
        ..loginResult = buildSession()
        ..listCompaniesResult = companies;

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );

      container.read(authProvider.notifier);
      await deepSettle();
      container.read(companyStateProvider);
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      await container
          .read(companyStateProvider.notifier)
          .setCompany(companies[1]);
      await deepSettle();

      expect(container.read(companyStateProvider).current?.id, 'c2');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('current_company_id'), 'c2');

      container.dispose();
    });
  });

  group('clear', () {
    test('resets to empty state', () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession()
        ..listCompaniesResult = [buildCompany()];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );

      container.read(authProvider.notifier);
      await deepSettle();
      container.read(companyStateProvider);
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(container.read(companyStateProvider).companies, isNotEmpty);

      container.read(companyStateProvider.notifier).clear();

      final state = container.read(companyStateProvider);
      expect(state.companies, isEmpty);
      expect(state.current, isNull);

      container.dispose();
    });
  });

  group('error handling', () {
    test('API error -> errorMessage set', () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession()
        ..listCompaniesError = Exception('API down');

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );

      container.read(authProvider.notifier);
      await deepSettle();
      container.read(companyStateProvider);
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      final state = container.read(companyStateProvider);
      expect(state.errorMessage, contains('API down'));

      container.dispose();
    });
  });

  group('auto-load on auth change', () {
    test('companies clear when auth becomes unauthenticated', () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession()
        ..listCompaniesResult = [buildCompany()];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );

      container.read(authProvider.notifier);
      await deepSettle();
      container.read(companyStateProvider);
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(container.read(companyStateProvider).companies, isNotEmpty);

      // Logout clears auth -> company listener should clear companies
      await container.read(authProvider.notifier).logout();
      await deepSettle();

      final state = container.read(companyStateProvider);
      expect(state.companies, isEmpty);
      expect(state.current, isNull);

      container.dispose();
    });
  });

  // =====================================================================
  // Stage B (TRD 50-22): the provider-closure -> Notifier.build() port.
  // =====================================================================

  /// Open a REAL, long-lived subscription. Never `container.read` — riverpod 3
  /// treats an unlistened provider as PAUSED and `ProviderElement.onCancel`
  /// deactivates every subscription that element created, cascading the pause
  /// up the whole auth -> company -> nav chain. `read` opens a subscription
  /// and closes it immediately, so it leaves zero listeners. See
  /// doc/riverpod-3-migration.md §3.2.1. This is the company-side twin of
  /// `subscribeNav` in nav_provider_test.dart.
  void subscribeCompany(ProviderContainer container) {
    container.listen<CompanyState>(companyStateProvider, (_, _) {});
  }

  group('build() wiring', () {
    test('the bootstrap microtask loads with the auth session preferred '
        'company when the container is already authenticated at build time',
        () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession(companyId: 'c2')
        ..listCompaniesResult = [
          buildCompany(id: 'c1', name: 'First'),
          buildCompany(id: 'c2', name: 'Second'),
        ];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      // Authenticate FIRST, with company never built. The listener therefore
      // cannot be the thing that loads — only build()'s bootstrap can, because
      // it is the sole path that runs when the provider is first read.
      container.listen<AuthState>(authProvider, (_, _) {});
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();
      expect(repository.listCompaniesCalls, 0,
          reason: 'premise: company must not have been built yet');

      // NOW build company. Only the bootstrap can load here.
      subscribeCompany(container);
      await deepSettle();

      expect(repository.listCompaniesCalls, 1);
      expect(container.read(companyStateProvider).companies.length, 2);
      expect(container.read(companyStateProvider).current?.id, 'c2',
          reason: 'the bootstrap must pass auth.companyId as preferred');
    });

    test('one auth change after a forced rebuild triggers exactly ONE reload — '
        'listeners re-register without duplicating', () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession()
        ..listCompaniesResult = [buildCompany()];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      subscribeCompany(container);
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();
      expect(repository.listCompaniesCalls, 1,
          reason: 'premise: exactly one load before the rebuild');

      // Force build() to re-run. Under the old StateNotifierProvider the
      // closure re-ran and re-registered; under Notifier the INSTANCE is
      // reused and build() re-runs on it. Either way a leaked first
      // subscription would make the next auth change load twice. That is the
      // failure mode a manual "already registered" guard produces.
      container.invalidate(companyStateProvider);
      await deepSettle();
      final afterRebuild = repository.listCompaniesCalls;

      // ONE auth change: a genuinely different access token, so the
      // listener's `previous?.accessToken != next.accessToken` branch is
      // actually taken. A same-token re-login would short-circuit and the
      // assertion would pass for the wrong reason.
      repository.loginResult = buildSession(accessToken: 'rotated-token');
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(repository.listCompaniesCalls - afterRebuild, 1,
          reason: 'exactly one reload per auth change, not two');
    });

    test('the notifier instance is REUSED across a rebuild, and build() '
        're-runs on it (§3.6)', () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession()
        ..listCompaniesResult = [buildCompany()];
      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      subscribeCompany(container);
      await deepSettle();

      final before = container.read(companyStateProvider.notifier);
      container.invalidate(companyStateProvider);
      await deepSettle();
      final after = container.read(companyStateProvider.notifier);

      // MEASURED false under StateNotifierProvider (it ran the constructor
      // afresh) and true under NotifierProvider. Recorded because it is the
      // reason any field outside `state` must be reset explicitly in build().
      expect(identical(before, after), true);
    });
  });

  group('B2C fast path', () {
    test('returns a synthetic personal workspace with an EMPTY companies list '
        'and makes no API call', () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession(companyId: 'personal-1')
        ..listCompaniesResult = [buildCompany(id: 'should-not-be-used')];

      final container = ProviderContainer(
        overrides: [
          platformRepositoryProvider.overrideWithValue(repository),
          platformConfigProvider.overrideWithValue(
            const EdenPlatformConfig(mode: PlatformMode.b2c),
          ),
        ],
      );
      addTearDown(container.dispose);
      subscribeCompany(container);
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      final state = container.read(companyStateProvider);
      // The empty list is the CONTRACT, not an accident: CompanySwitcher
      // hides itself when there are no companies to switch between.
      expect(state.companies, isEmpty);
      expect(container.read(companiesProvider), isEmpty);
      expect(state.current?.id, 'personal-1');
      expect(state.current?.slug, 'personal');
      expect(state.current?.companyType, 'personal');
      expect(state.current?.name, 'Dev User');
      // No network call at all — that is the "silently, from the JWT" part.
      expect(repository.listCompaniesCalls, 0);
    });

    test('CONTROL: the same fixture in B2B mode DOES call the API and DOES '
        'populate companies', () async {
      SharedPreferences.setMockInitialValues({});
      repository
        ..loginResult = buildSession(companyId: 'personal-1')
        ..listCompaniesResult = [buildCompany(id: 'personal-1')];

      // Identical to the test above except for the mode. Without this control
      // the zero-call assertion above could pass because nothing loaded at
      // all, rather than because the fast path short-circuited.
      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      subscribeCompany(container);
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(repository.listCompaniesCalls, 1);
      expect(container.read(companyStateProvider).companies, isNotEmpty);
    });
  });

  group('_selectCompany precedence', () {
    test('preferred BEATS stored', () async {
      // The two existing tests cover stored-wins-over-first and
      // first-as-fallback. This is the missing rung: both candidates present
      // and DIFFERENT, so the ordering is actually exercised.
      SharedPreferences.setMockInitialValues({
        'current_company_id': 'c3',
      });
      repository
        ..loginResult = buildSession(companyId: 'c2')
        ..listCompaniesResult = [
          buildCompany(id: 'c1'),
          buildCompany(id: 'c2'),
          buildCompany(id: 'c3'),
        ];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      subscribeCompany(container);
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(container.read(companyStateProvider).current?.id, 'c2',
          reason: 'preferred (c2) must win over stored (c3)');
      // ...and the winner is persisted back.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('current_company_id'), 'c2');
    });

    test('a preferred id that matches NO company falls through to stored',
        () async {
      SharedPreferences.setMockInitialValues({
        'current_company_id': 'c3',
      });
      repository
        ..loginResult = buildSession(companyId: 'nonexistent')
        ..listCompaniesResult = [buildCompany(id: 'c1'), buildCompany(id: 'c3')];

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      subscribeCompany(container);
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(container.read(companyStateProvider).current?.id, 'c3');
    });
  });

  group('post-await disposal guards', () {
    test('a load that resolves AFTER disposal does not throw and writes no '
        'state', () async {
      SharedPreferences.setMockInitialValues({});
      final gate = Completer<List<PlatformCompany>>();
      final repo = _GatedCompanyRepository(gate);
      repo.loginResult = buildSession();

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repo)],
      );
      subscribeCompany(container);
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      // Premise: the load is genuinely in flight and parked on the gate.
      expect(repo.listCompaniesCalls, 1);
      expect(gate.isCompleted, false);

      container.dispose();
      gate.complete([buildCompany()]);
      // The unguarded code path would throw
      // "Bad state: Tried to use CompanyNotifier after 'dispose' was called"
      // out of this settle as an unhandled async error.
      await deepSettle();
    });

    test('CONTROL: the same flow UNDISPOSED really does write the state',
        () async {
      // Without this control the test above proves nothing — it would pass
      // just as happily if the load never ran at all.
      SharedPreferences.setMockInitialValues({});
      final gate = Completer<List<PlatformCompany>>();
      final repo = _GatedCompanyRepository(gate);
      repo.loginResult = buildSession();

      final container = ProviderContainer(
        overrides: [platformRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      subscribeCompany(container);
      await deepSettle();
      await container.read(authProvider.notifier).login('a@b.com', 'pass');
      await deepSettle();

      expect(repo.listCompaniesCalls, 1);
      expect(container.read(companyStateProvider).companies, isEmpty,
          reason: 'premise: nothing written while the load is parked');

      gate.complete([buildCompany(id: 'arrived')]);
      await deepSettle();

      expect(container.read(companyStateProvider).companies.single.id,
          'arrived');
    });
  });

  group('source: Stage A is finished for this file', () {
    test('company_provider.dart is on Notifier, has no Ref field and no shim',
        () {
      final src =
          File('lib/src/company/company_provider.dart').readAsStringSync();
      expect(src.length, greaterThan(2000),
          reason: 'the file must actually have been read');

      // Strip line comments: this file names the old base class in dartdoc as
      // history, and a whole-file grep cannot tell a declaration from a
      // mention. Banned identifiers are assembled at runtime so this test file
      // does not match its own rule.
      final code = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.contains('class CompanyNotifier extends Notifier<CompanyState>'),
          true,
          reason: 'comment-stripping must not remove the declaration');
      expect(code.length, lessThan(src.length),
          reason: 'comment-stripping must actually have removed something');

      final banned = ['State', 'Notifier'].join();
      expect(code.contains(banned), false);
      final legacyImport = "flutter_riverpod/${'legacy'}.dart";
      expect(src.contains("import 'package:$legacyImport'"), false);

      // A shadowing `final Ref ref;` compiles and then behaves differently
      // across rebuilds from the inherited Notifier.ref.
      expect(RegExp(r'final\s+Ref\s+ref\s*;').hasMatch(code), false);
      // ...and no constructor taking a Ref survives either.
      expect(code.contains('CompanyNotifier(this.ref)'), false);

      // The wiring moved, it did not evaporate: one subscription, one
      // bootstrap, and registration BEFORE the microtask is scheduled.
      expect('ref.listen'.allMatches(code).length, 1);
      expect('Future.microtask'.allMatches(code).length, 1);
      expect(code.indexOf('ref.listen'),
          lessThan(code.indexOf('Future.microtask')),
          reason: 'listeners must be registered before the bootstrap is '
              'scheduled, so a bootstrap-driven state change cannot land '
              'before the subscription exists');

      // The derived providers keep their identifiers: 50-24 migrates the
      // widgets that read them and 50-13/50-16 cite them.
      expect(code.contains('final currentCompanyProvider = Provider<PlatformCompany?>'),
          true);
      expect(code.contains('final companiesProvider = Provider<List<PlatformCompany>>'),
          true);
      expect(code.contains(
          'NotifierProvider<CompanyNotifier, CompanyState>(CompanyNotifier.new)'),
          true);

      // The remedy is scoped to the notifier. An `operator ==` on
      // CompanyState would change equality for every consumer in 18+ packages.
      expect(code.contains('operator =='), false);

      // The B2C fast path's marker comment is a deliberate contract note; the
      // behaviour test above is the real guard, this catches a silent deletion.
      expect(src.contains('empty = CompanySwitcher hidden'), true);
    });
  });
}

/// [PlatformRepository] whose `listCompanies` parks on a [Completer], so a test
/// can dispose the container mid-await and prove the post-await guard holds.
/// Hand-built: `FakePlatformRepository` resolves immediately, and an immediate
/// resolution cannot exercise a disposal that happens DURING the await.
class _GatedCompanyRepository extends FakePlatformRepository {
  _GatedCompanyRepository(this._gate);

  final Completer<List<PlatformCompany>> _gate;

  @override
  Future<List<PlatformCompany>> listCompanies(String accessToken) {
    listCompaniesCalls++;
    return _gate.future;
  }
}
