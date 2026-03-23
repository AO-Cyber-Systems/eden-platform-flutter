import 'package:flutter_riverpod/flutter_riverpod.dart';
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
