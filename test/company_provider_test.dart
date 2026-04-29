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
      final state = container.read(companyStateProvider);
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
}
