/// Abstraction over token persistence so the storage backend can be swapped
/// without touching `AuthNotifier`.
///
/// The default implementation (`SecureTokenStorage`) uses
/// `flutter_secure_storage` (Keychain on iOS, EncryptedSharedPreferences on
/// Android). Tests inject a fake; consumer apps can override via
/// `tokenStorageProvider` if they need a custom storage strategy.
///
/// This interface is intentionally minimal: read, write, clear. AuthNotifier
/// owns the in-memory token state on `AuthState.session`; the storage layer
/// is purely the persistence side.
abstract class TokenStorage {
  /// Returns the persisted access token or `null` if none / cleared.
  ///
  /// Implementations may transparently migrate from a legacy backend (e.g.
  /// `shared_preferences` -> secure storage) on first read. AuthNotifier
  /// is unaware that migration happened.
  Future<String?> readAccessToken();

  /// Returns the persisted refresh token or `null`.
  Future<String?> readRefreshToken();

  /// Persists the access token, or deletes it when `value` is `null`.
  Future<void> writeAccessToken(String? value);

  /// Persists the refresh token, or deletes it when `value` is `null`.
  Future<void> writeRefreshToken(String? value);

  /// Removes both tokens from every backing store (secure storage AND any
  /// legacy `shared_preferences` straggler). Used by logout AND by company
  /// switch as defense-in-depth (CLI-07 — see eden-biz-flutter.SAAS
  /// 10-08-SUMMARY.md TODO marker).
  Future<void> clear();
}
