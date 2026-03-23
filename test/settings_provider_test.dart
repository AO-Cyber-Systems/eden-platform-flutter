import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Import the ThemeMode from settings_provider (not Flutter's)
import 'package:eden_platform_flutter/src/settings/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('defaults', () {
    test('initial state has system theme, en locale, notifications enabled',
        () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final state = container.read(settingsProvider);
      expect(state.themeMode, ThemeMode.system);
      expect(state.locale, 'en');
      expect(state.notificationsEnabled, true);
    });
  });

  group('load', () {
    test('restores saved theme/locale/notifications from SharedPreferences',
        () async {
      SharedPreferences.setMockInitialValues({
        'theme_mode': 'dark',
        'locale': 'es',
        'notifications_enabled': false,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(settingsProvider.notifier).load();

      final state = container.read(settingsProvider);
      expect(state.themeMode, ThemeMode.dark);
      expect(state.locale, 'es');
      expect(state.notificationsEnabled, false);
    });

    test('falls back to system for invalid theme', () async {
      SharedPreferences.setMockInitialValues({
        'theme_mode': 'invalid_theme',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(settingsProvider.notifier).load();

      expect(container.read(settingsProvider).themeMode, ThemeMode.system);
    });
  });

  group('setThemeMode', () {
    test('updates state + persists to SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(settingsProvider.notifier).setThemeMode(ThemeMode.dark);

      expect(container.read(settingsProvider).themeMode, ThemeMode.dark);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('theme_mode'), 'dark');
    });
  });

  group('setLocale', () {
    test('updates state + persists', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(settingsProvider.notifier).setLocale('fr');

      expect(container.read(settingsProvider).locale, 'fr');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('locale'), 'fr');
    });
  });

  group('setNotificationsEnabled', () {
    test('updates state + persists', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container
          .read(settingsProvider.notifier)
          .setNotificationsEnabled(false);

      expect(container.read(settingsProvider).notificationsEnabled, false);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('notifications_enabled'), false);
    });

    test('toggle back to enabled', () async {
      SharedPreferences.setMockInitialValues({'notifications_enabled': false});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(settingsProvider.notifier).load();
      expect(container.read(settingsProvider).notificationsEnabled, false);

      await container
          .read(settingsProvider.notifier)
          .setNotificationsEnabled(true);

      expect(container.read(settingsProvider).notificationsEnabled, true);
    });
  });
}
