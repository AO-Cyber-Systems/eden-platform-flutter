// riverpod 3.x moved StateNotifier/StateNotifierProvider out of the main barrel
// into legacy.dart. STAGE A of AOID objective 50's riverpod alignment
// (50-CONTEXT.md D2, TRD 50-06) — compiles on 3.x with ZERO API change.
//
// NOTE: this file is the ONLY one where the main `flutter_riverpod.dart` import
// had to be DROPPED rather than kept alongside legacy.dart. Every symbol it uses
// (StateNotifier, StateNotifierProvider) now comes from legacy.dart, and the
// `ThemeMode` below is this package's own enum, not Flutter's — so after the
// barrel split the main barrel became genuinely unused and tripped
// `unused_import`.
//
// This import is TEMPORARY. TRD 50-22 migrates SettingsNotifier to the 3.x
// Notifier API and must RE-ADD `package:flutter_riverpod/flutter_riverpod.dart`
// when it does, since `Notifier`/`NotifierProvider` live in the main barrel.
// See doc/riverpod-3-migration.md.
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/storage_keys.dart';

class SettingsState {
  final ThemeMode themeMode;
  final String locale;
  final bool notificationsEnabled;

  const SettingsState({
    this.themeMode = ThemeMode.system,
    this.locale = 'en',
    this.notificationsEnabled = true,
  });

  SettingsState copyWith({
    ThemeMode? themeMode,
    String? locale,
    bool? notificationsEnabled,
  }) {
    return SettingsState(
      themeMode: themeMode ?? this.themeMode,
      locale: locale ?? this.locale,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    );
  }
}

enum ThemeMode { system, light, dark }

class SettingsNotifier extends StateNotifier<SettingsState> {
  SettingsNotifier() : super(const SettingsState());

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final themeStr = prefs.getString(StorageKeys.kThemeMode) ?? 'system';
    final locale = prefs.getString(StorageKeys.kLocale) ?? 'en';
    final notifications = prefs.getBool(StorageKeys.kNotificationsEnabled) ?? true;

    state = SettingsState(
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == themeStr,
        orElse: () => ThemeMode.system,
      ),
      locale: locale,
      notificationsEnabled: notifications,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.kThemeMode, mode.name);
    state = state.copyWith(themeMode: mode);
  }

  Future<void> setLocale(String locale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.kLocale, locale);
    state = state.copyWith(locale: locale);
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(StorageKeys.kNotificationsEnabled, enabled);
    state = state.copyWith(notificationsEnabled: enabled);
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, SettingsState>((ref) {
  return SettingsNotifier();
});
