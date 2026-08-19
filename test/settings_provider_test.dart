import 'dart:io';

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

  // ---------------------------------------------------------------------
  // Stage B riverpod-3 mechanics. `SettingsNotifier` is the CONTROL CASE of
  // The riverpod migration: it holds no `Ref`, registers no `ref.listen`, schedules no
  // bootstrap microtask and has no `clear()`. Everything below therefore
  // isolates the *mechanics* of the StateNotifier -> Notifier port, with the
  // wiring that company/nav carry removed as a variable. If a mechanic is
  // wrong, it is wrong here, where the signal is clean.
  // ---------------------------------------------------------------------
  group('riverpod 3 mechanics (Stage B control case)', () {
    test('build() yields the default state, and a rebuild returns to it',
        () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // A real subscription, not `read`: riverpod 3 pauses an unlistened
      // provider. See doc/riverpod-3-migration.md §3.2.1.
      container.listen<SettingsState>(settingsProvider, (_, _) {});

      await container.read(settingsProvider.notifier).setThemeMode(ThemeMode.dark);
      // Premise guard — the rebuild assertion below is meaningless unless the
      // state genuinely moved off the default first.
      expect(container.read(settingsProvider).themeMode, ThemeMode.dark,
          reason: 'fixture must be non-default before the rebuild');

      container.invalidate(settingsProvider);

      expect(container.read(settingsProvider).themeMode, ThemeMode.system);
      expect(container.read(settingsProvider).locale, 'en');
      expect(container.read(settingsProvider).notificationsEnabled, true);
    });

    test('the notifier INSTANCE is reused across a rebuild — nothing outside '
        'state is wiped for you (§3.6)', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen<SettingsState>(settingsProvider, (_, _) {});

      final before = container.read(settingsProvider.notifier);
      container.invalidate(settingsProvider);
      final after = container.read(settingsProvider.notifier);

      // riverpod 3.3.2, providers/notifier/orphan.dart:57-60 — "the Notifier
      // will not be recreated. Its instance will be preserved between
      // executions of build." `StateNotifierProvider` did the opposite: it ran
      // the constructor afresh, so every field outside `state` was discarded
      // for free. This assertion is what makes that difference visible, and it
      // is the reason company/nav must reset explicitly in build() anything
      // that has to start fresh.
      expect(identical(before, after), true,
          reason: 'riverpod 3 REUSES the Notifier instance across a rebuild');
      //...and `build()` still re-ran on that reused instance.
      expect(container.read(settingsProvider).themeMode, ThemeMode.system);
    });

    test('CONTROL: settingsProvider is keep-alive — state survives the last '
        'listener detaching', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final sub = container.listen<SettingsState>(settingsProvider, (_, _) {});
      await container.read(settingsProvider.notifier).setLocale('fr');
      expect(container.read(settingsProvider).locale, 'fr');

      // Drop the only listener. An auto-dispose provider would reset here; a
      // user's theme/locale silently reverting on the last consumer unmounting
      // is the realistic defect this guards. `NotifierProvider` takes
      // `isAutoDispose` as a plain constructor flag (orphan.dart:86) — easy to
      // add by accident during the port, invisible to every other test.
      sub.close();

      // The pump is LOAD-BEARING, not politeness. riverpod SCHEDULES disposal
      // rather than running it inside `close()`, so reading synchronously on
      // the next line observes the pre-disposal value and the assertion passes
      // even when the provider IS auto-dispose. Measured: without this await,
      // mutation S1 (`isAutoDispose: true`) SURVIVED this very test.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(container.read(settingsProvider).locale, 'fr',
          reason: 'settingsProvider must not be auto-dispose');
    });

    test('settings_provider.dart is on Notifier and carries no Stage A shim',
        () {
      final src =
          File('lib/src/settings/settings_provider.dart').readAsStringSync();
      // Fixture guard: silence must not be vacuous.
      expect(src.length, greaterThan(1000),
          reason: 'the file must actually have been read');

      // A whole-file grep cannot tell a DECLARATION from a MENTION, and this
      // file names the old base class in comments as history. Strip line
      // comments and assert against CODE only. The banned identifier is
      // assembled at runtime so this test file does not match its own rule.
      final code =
          src.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');
      expect(code.contains('class SettingsNotifier extends Notifier<SettingsState>'),
          true,
          reason: 'comment-stripping must not remove the declaration');
      expect(code.length, lessThan(src.length),
          reason: 'comment-stripping must actually have removed something');

      expect(
          code.contains(
              'NotifierProvider<SettingsNotifier, SettingsState>(SettingsNotifier.new)'),
          true);

      final banned = ['State', 'Notifier'].join();
      expect(code.contains(banned), false,
          reason: 'no $banned may remain in the CODE of this file');
      final legacyImport = "flutter_riverpod/${'legacy'}.dart";
      expect(src.contains("import 'package:$legacyImport'"), false,
          reason: 'the Stage A legacy shim import must be gone');

      // The package's own ThemeMode enum shadows Flutter's and is exported
      // through eden_platform.dart. Removing or renaming it is a
      // consumer-visible API change and is explicitly out of scope here.
      expect(RegExp(r'^enum ThemeMode\b', multiLine: true).allMatches(code).length, 1);
    });
  });
}
