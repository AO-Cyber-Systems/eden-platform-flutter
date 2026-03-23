/// Named constants for all SharedPreferences storage keys.
///
/// Using a single source of truth prevents subtle bugs when one instance
/// of a key string is updated but others are missed.
abstract final class StorageKeys {
  static const String kAccessToken = 'access_token';
  static const String kRefreshToken = 'refresh_token';
  static const String kThemeMode = 'theme_mode';
  static const String kLocale = 'locale';
  static const String kNotificationsEnabled = 'notifications_enabled';
  static const String kCurrentCompanyId = 'current_company_id';
}
