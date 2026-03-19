import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    final themeStr = prefs.getString('theme_mode') ?? 'system';
    final locale = prefs.getString('locale') ?? 'en';
    final notifications = prefs.getBool('notifications_enabled') ?? true;

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
    await prefs.setString('theme_mode', mode.name);
    state = state.copyWith(themeMode: mode);
  }

  Future<void> setLocale(String locale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('locale', locale);
    state = state.copyWith(locale: locale);
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_enabled', enabled);
    state = state.copyWith(notificationsEnabled: enabled);
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, SettingsState>((ref) {
  return SettingsNotifier();
});
