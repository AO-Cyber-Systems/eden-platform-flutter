// STAGE B of AOID objective 50's riverpod alignment (50-CONTEXT.md D2,
// TRD 50-22). Stage A parked this file on the `legacy.dart` shim; that shim is
// now gone and the main barrel is back, because `Notifier`/`NotifierProvider`
// live in it. See doc/riverpod-3-migration.md §3.3.
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

/// Persisted user preferences, on riverpod 3's [Notifier].
///
/// This is the CONTROL CASE of TRD 50-22's Stage B unit: unlike
/// [CompanyNotifier] and [NavNotifier] it holds no `Ref`, registers no
/// `ref.listen`, schedules no bootstrap microtask and has no `clear()`. It
/// therefore isolates the port's *mechanics* with the wiring removed.
///
/// Two consequences of the base-class change matter even here, and both are
/// pinned by test in `test/settings_provider_test.dart`:
///
/// * **The instance is REUSED across a rebuild.** riverpod 3.3.2's own dartdoc
///   on `Notifier.build` (providers/notifier/orphan.dart:57-60) says the
///   notifier "will not be recreated. Its instance will be preserved between
///   executions of build." `StateNotifierProvider` ran the constructor afresh
///   each time, so fields outside `state` were discarded for free. This class
///   has no such fields, so there is nothing to reset in [build] — that is
///   exactly what makes it the clean control. Company and nav are not so
///   lucky; see doc/riverpod-3-migration.md §3.6.
/// * **The provider stays keep-alive.** `NotifierProvider` takes
///   `isAutoDispose` as a plain constructor flag (orphan.dart:86). Setting it
///   here would silently revert a user's theme and locale the moment the last
///   consumer unmounted.
///
/// The `==` update filter that suppressed the sign-out signal at the auth
/// epicentre (§3.8) does NOT bite here: every assignment in this class
/// allocates a fresh, non-`const` [SettingsState] (via `copyWith` or a direct
/// constructor call), so identity always differs. The hazard needs a
/// *canonicalized const sentinel* to be re-assigned, and nothing in this file
/// re-assigns one — `const SettingsState()` appears only as [build]'s return.
class SettingsNotifier extends Notifier<SettingsState> {
  @override
  SettingsState build() => const SettingsState();

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

// Signature read from the RESOLVED package, not the changelog:
// `NotifierProvider(this._createNotifier, {name, dependencies,
// isAutoDispose = false, retry})` — riverpod 3.3.2,
// lib/src/providers/notifier/orphan.dart:78-94. `isAutoDispose` defaults to
// false, so this is keep-alive, matching the StateNotifierProvider it replaces.
final settingsProvider =
    NotifierProvider<SettingsNotifier, SettingsState>(SettingsNotifier.new);
