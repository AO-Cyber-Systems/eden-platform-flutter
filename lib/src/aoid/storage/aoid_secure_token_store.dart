// AoidSecureTokenStore — the AOID module's NATIVE-ONLY token store.
//
// RIVERPOD-FREE BY CONSTRUCTION (see aoid_token_store.dart's header).
//
// It takes a TokenStorage rather than a FlutterSecureStorage on purpose: this
// module must not depend on flutter_secure_storage directly, because eden pins
// it to 9.2.4 exactly while AODex overrides to ^10.0.0. §5.4.

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../auth/token_storage.dart';
import 'aoid_token_store.dart';

/// Delegates both tokens to an injected [TokenStorage] — in production, the
/// OS keychain via `SecureTokenStorage`. **Mode B, native only.**
///
/// ## It refuses to construct on web, and that is the whole point
///
/// `flutter_secure_storage_web` 1.2.1 stores the ciphertext **and its AES key**
/// side by side in `window.localStorage` (see the plugin's own
/// `flutter_secure_storage_web.dart:116,152`). Against XSS — the threat D4
/// exists for — that is plaintext with extra steps. So on web this class is not
/// "less secure"; it provides no security at all for the asset that matters.
///
/// The failure is at **construction**, not at the first write. A wiring mistake
/// then surfaces in a test at wiring time rather than in production at 3am,
/// after a refresh token has already been written.
class AoidSecureTokenStore implements AoidTokenStore {
  /// Wraps [_delegate].
  ///
  /// [isWeb] defaults to [kIsWeb] and exists as an injectable seam because
  /// `kIsWeb` is a compile-time constant and `flutter test` is never web — a
  /// `kIsWeb`-gated branch is otherwise untestable. Same pattern as
  /// `connectCookieInterceptorWebForTest`
  /// (lib/src/networking/connect_cookie_interceptor.dart:63-67).
  ///
  /// Throws [UnsupportedError] when [isWeb] is true.
  AoidSecureTokenStore(this._delegate, {bool isWeb = kIsWeb}) {
    if (isWeb) {
      throw UnsupportedError(
        'AoidSecureTokenStore is native-only. On web, flutter_secure_storage_web '
        'stores the ciphertext AND its AES key in window.localStorage, so a '
        'refresh token there is readable by any XSS — the configuration '
        'the design notes forbids. Use AoidMemoryTokenStore + Mode A.',
      );
    }
  }

  final TokenStorage _delegate;

  @override
  Future<String?> readAccessToken() => _delegate.readAccessToken();

  @override
  Future<void> writeAccessToken(String? value) =>
      _delegate.writeAccessToken(value);

  @override
  Future<void> writeRefreshToken(String? value) =>
      _delegate.writeRefreshToken(value);

  @override
  Future<String?> readRefreshToken() => _delegate.readRefreshToken();

  @override
  Future<void> clear() => _delegate.clear();
}
