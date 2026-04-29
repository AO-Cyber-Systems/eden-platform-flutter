import 'dart:async';

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
/// Reference: 10-RESEARCH.md Pattern 1, Pitfall 1 (DO NOT bump to 10.x), and
/// Pitfall 8 (iOS Simulator -25308 retry).
class SecureTokenStorage implements TokenStorage {
  /// Creates a storage instance. Pass an injected [FlutterSecureStorage] for
  /// testing; the default applies the production AndroidOptions/iOSOptions
  /// per the class doc.
  SecureTokenStorage([FlutterSecureStorage? secure])
      : _secure = secure ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  final FlutterSecureStorage _secure;
  // Per-key in-flight read+migration. Concurrent readers attach to the same
  // Future so the migration runs exactly once across N callers.
  final Map<String, Future<String?>> _inflightByKey = <String, Future<String?>>{};

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

    // CRITICAL: write-then-clear. Reverse order would lose the user's
    // session if the secure-write fails after the prefs.remove succeeds.
    await _secure.write(key: key, value: legacy);
    await prefs.remove(key);
    return legacy;
  }

  Future<String?> _readSecureWithRetry(String key, {int attempts = 3}) async {
    for (var i = 0; i < attempts; i++) {
      try {
        return await _secure.read(key: key);
      } on PlatformException catch (e) {
        // iOS Simulator first-launch flake — see 10-RESEARCH.md Pitfall 8.
        // -25308 is errSecAuth; transient. Retry up to `attempts` times with
        // 100ms backoff. Any other code is a real failure — rethrow.
        if (e.code != '-25308' || i == attempts - 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
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
    if (value == null) {
      await _secure.delete(key: key);
    } else {
      await _secure.write(key: key, value: value);
    }
  }

  @override
  Future<void> clear() async {
    // Secure side first.
    await _secure.delete(key: StorageKeys.kAccessToken);
    await _secure.delete(key: StorageKeys.kRefreshToken);
    // Also clear any legacy shared_preferences stragglers (defense-in-depth
    // for partial migrations and CLI-07 company-switch wipe).
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(StorageKeys.kAccessToken);
    await prefs.remove(StorageKeys.kRefreshToken);
  }
}
