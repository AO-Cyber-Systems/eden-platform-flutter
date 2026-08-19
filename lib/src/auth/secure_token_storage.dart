import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/storage_keys.dart';
import 'token_storage.dart';

/// `flutter_secure_storage`-backed `TokenStorage` with transparent migration
/// from `shared_preferences`.
///
/// **Migration semantics:** On the first read, if no value exists in secure
/// storage, falls back to `shared_preferences`. If a legacy value is found,
/// writes it to secure storage, then clears it from `shared_preferences`.
/// **Order is write-then-clear** — if the secure-write fails (e.g. disk full,
/// keychain not yet available), the legacy value remains in
/// `shared_preferences` so a retry can complete the migration without losing
/// the user's session.
///
/// **Single-flight:** concurrent reads during an in-flight migration await
/// the same `Completer` so the legacy value migrates exactly once even under
/// concurrent access.
///
/// **iOS Simulator -25308 retry:** The first keychain read after fresh
/// simulator boot occasionally throws `PlatformException(-25308)` (errSecAuth).
/// Retried up to 3 times with 100ms backoff before rethrowing.
///
/// **Android encryption:** `AndroidOptions(encryptedSharedPreferences: true)`
/// is REQUIRED to enable Jetpack-encrypted shared preferences. Without it,
/// values land in plain Android Keystore-backed preferences (still secured
/// against other apps but NOT encrypted at rest by Jetpack Security crypto).
///
/// **iOS keychain accessibility:** `KeychainAccessibility.first_unlock` keeps
/// tokens accessible after the device is unlocked once after boot — matches
/// user mental model.
///
/// **Refresh token on web:** the
/// refresh token is never persisted to `shared_preferences`, and a legacy one
/// found there is never copied into secure storage. On web both of those are
/// `localStorage` — `flutter_secure_storage_web` keeps the ciphertext and its
/// AES key there side by side — so either write makes the token readable by
/// any XSS. The access token keeps both behaviours; see [_writeOrDelete].
///
/// Reference: the design notes Pattern 1, Pitfall 1 (DO NOT bump to 10.x), and
/// Pitfall 8 (iOS Simulator -25308 retry).
class SecureTokenStorage implements TokenStorage {
  /// Creates a storage instance. Pass an injected [FlutterSecureStorage] for
  /// testing; the default applies the production AndroidOptions/iOSOptions
  /// per the class doc.
  SecureTokenStorage([FlutterSecureStorage? secure]) : this._(secure, kIsWeb);

  /// Test seam for the web-specific refresh-token behaviour.
  ///
  /// [kIsWeb] is a compile-time constant and `flutter test` is never web, so
  /// the web branches below are otherwise unreachable from a unit test. Same
  /// pattern as `connectCookieInterceptorWebForTest`
  /// (lib/src/networking/connect_cookie_interceptor.dart:63-67).
  @visibleForTesting
  SecureTokenStorage.forPlatform({
    FlutterSecureStorage? secure,
    required bool isWeb,
  }) : this._(secure, isWeb);

  SecureTokenStorage._(FlutterSecureStorage? secure, this._isWeb)
    : _secure =
          secure ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  final FlutterSecureStorage _secure;
  final bool _isWeb;
  // Per-key in-flight read+migration. Concurrent readers attach to the same
  // Future so the migration runs exactly once across N callers.
  final Map<String, Future<String?>> _inflightByKey =
      <String, Future<String?>>{};

  @override
  Future<String?> readAccessToken() =>
      _readWithMigration(StorageKeys.kAccessToken);

  @override
  Future<String?> readRefreshToken() =>
      _readWithMigration(StorageKeys.kRefreshToken);

  Future<String?> _readWithMigration(String key) {
    // Single-flight: if a read+migration is already in flight for this key,
    // attach to it. The first caller drives the actual work; subsequent
    // callers receive the same result.
    final existing = _inflightByKey[key];
    if (existing != null) return existing;

    final future = _doReadWithMigration(key).whenComplete(() {
      _inflightByKey.remove(key);
    });
    _inflightByKey[key] = future;
    return future;
  }

  Future<String?> _doReadWithMigration(String key) async {
    final secure = await _readSecureWithRetry(key);
    if (secure != null) return secure;

    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(key);
    if (legacy == null) return null;

    // AOID obj-50 / D4: on web, do NOT create a second persisted copy of the
    // refresh token. Migrating it means writing it into secure storage, which
    // on web is window.localStorage with the AES key alongside — the state D4
    // forbids. The pre-existing prefs value is deliberately left ALONE and
    // still returned: purging tokens users already hold needs a coordinated
    // eden-biz change and is escalated by the spec SUMMARY, not done here.
    if (_isWeb && key == StorageKeys.kRefreshToken) {
      return legacy;
    }

    // CRITICAL: write-then-clear. Reverse order would lose the user's
    // session if the secure-write fails after the prefs.remove succeeds.
    try {
      await _secure.write(key: key, value: legacy);
      await prefs.remove(key);
    } catch (_) {
      // Secure write can throw on web (no working secure-storage impl). Leave
      // the legacy value in prefs so the session persists and restores from
      // there next time, rather than losing it.
    }
    return legacy;
  }

  Future<String?> _readSecureWithRetry(String key, {int attempts = 3}) async {
    for (var i = 0; i < attempts; i++) {
      try {
        return await _secure.read(key: key);
      } on PlatformException catch (e) {
        // iOS Simulator first-launch flake — see the design notes Pitfall 8.
        // -25308 is errSecAuth; transient. Retry up to `attempts` times with
        // 100ms backoff. Any other code is a real failure — rethrow.
        if (e.code != '-25308' || i == attempts - 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } catch (_) {
        // Non-PlatformException failures: MissingPluginException or a Web Crypto
        // DOMException on web, FormatException from malformed ciphertext.
        // Retrying won't help, and a throw here would bubble up and stall auth
        // bootstrap — treat an unreadable value as absent.
        return null;
      }
    }
    return null;
  }

  @override
  Future<void> writeAccessToken(String? value) =>
      _writeOrDelete(StorageKeys.kAccessToken, value);

  @override
  Future<void> writeRefreshToken(String? value) =>
      _writeOrDelete(StorageKeys.kRefreshToken, value);

  Future<void> _writeOrDelete(String key, String? value) async {
    try {
      if (value == null) {
        await _secure.delete(key: key);
      } else {
        await _secure.write(key: key, value: value);
      }
    } catch (_) {
      // Secure storage failed (notably on web, where flutter_secure_storage's
      // Web Crypto/localStorage calls can throw).
      //
      // For the ACCESS token we fall back to shared_preferences: it is
      // short-lived, and throwing here aborts login (the caller treats any
      // storage failure as an auth failure).
      //
      // For the REFRESH token we do NOT fall back. On web, shared_preferences
      // is localStorage, and so is flutter_secure_storage_web (it puts the AES
      // key and the ciphertext in localStorage side by side). Persisting a
      // refresh token to either makes it readable by any XSS. That is the
      // configuration AOID / the design notes forbids, and it is
      // what this package shipped until obj-50. Deleting (value == null, or an
      // empty string — a cookie-bound/web session clobbering a stale value)
      // still falls through to both backends: clearing must always be
      // best-effort, or a logout can strand a token.
      if (key == StorageKeys.kRefreshToken &&
          value != null &&
          value.isNotEmpty) {
        rethrow;
      }
      final prefs = await SharedPreferences.getInstance();
      if (value == null) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, value);
      }
    }
  }

  @override
  Future<void> clear() async {
    // Secure side first — tolerate web, where secure storage may throw.
    try {
      await _secure.delete(key: StorageKeys.kAccessToken);
      await _secure.delete(key: StorageKeys.kRefreshToken);
    } catch (_) {
      // Secure storage unavailable (web) — the prefs fallback copies below are
      // still cleared, so the session is fully wiped either way.
    }
    // Also clear any legacy / web-fallback shared_preferences copies
    // (defense-in-depth for partial migrations and CLI-07 company-switch wipe).
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(StorageKeys.kAccessToken);
    await prefs.remove(StorageKeys.kRefreshToken);
  }
}
