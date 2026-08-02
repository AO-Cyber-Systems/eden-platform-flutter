// AoidSession — just enough session to carry refresh-token custody honestly.
//
// RIVERPOD-FREE BY CONSTRUCTION (see storage/aoid_token_store.dart's header).
//
// DELIBERATELY MINIMAL. TRD 50-09 owns the full deployment-mode matrix
// (lib/src/aoid/parts/modes.dart) and extends this: AoidCodeSink, the Mode A
// BFF handshake, and the three-way restoreSession outcome all belong there,
// not here. TRD 50-02 is a security fix and has to stay reviewable on its own.
// 50-09 extends this.

import 'package:flutter/foundation.dart' show kIsWeb;

import 'storage/aoid_token_store.dart';

/// An AOID session, carrying the one property this TRD exists to make
/// observable: [hasClientHeldRefreshToken].
///
/// There is **no public unnamed constructor**. A session can only be built
/// through one of the three named constructors below, one per D4 mode, and
/// only [AoidSession.deviceKeychain] takes a refresh token at all. That is what
/// makes "no web configuration holds a client-held refresh token" a property of
/// the type rather than a convention:
///
/// - Modes A and C have **no refresh-token parameter** — they cannot express
///   one.
/// - Mode B is native-only and **throws** when asked to build a web session.
///
/// Enforced by test/aoid/storage/web_never_holds_refresh_token_test.dart, which
/// drives every posture in [AoidRefreshTokenPosture] and carries the native
/// positive control that keeps the web assertions from passing vacuously.
class AoidSession {
  const AoidSession._({
    required this.posture,
    required this.accessToken,
    required this.refreshToken,
    required this.isWeb,
  });

  /// **Mode A — BFF / confidential client.** The app's own backend holds the
  /// refresh token; this client got an httpOnly `SameSite` cookie. The default
  /// posture for web.
  ///
  /// Takes no refresh token: there is nothing to pass, on any platform.
  factory AoidSession.backendHeldCookie({
    String? accessToken,
    bool isWeb = kIsWeb,
  }) => AoidSession._(
    posture: AoidRefreshTokenPosture.backendHeldCookie,
    accessToken: accessToken,
    refreshToken: null,
    isWeb: isWeb,
  );

  /// **Mode C — same-origin.** Nothing is held; the session is bound to a
  /// cookie issued by AOID's own origin. Neither token is meaningful.
  factory AoidSession.sameOriginCookie({bool isWeb = kIsWeb}) => AoidSession._(
    posture: AoidRefreshTokenPosture.none,
    accessToken: null,
    refreshToken: null,
    isWeb: isWeb,
  );

  /// **Mode B — public client + PKCE, refresh token in the OS keychain.**
  ///
  /// Throws [UnsupportedError] when [isWeb] is true. The guard is keyed on the
  /// PLATFORM, not on whether a token happens to be present — a web caller
  /// holding a perfectly valid refresh token is exactly the case D4 forbids.
  ///
  /// [isWeb] defaults to [kIsWeb] and is injectable because `kIsWeb` is a
  /// compile-time constant that `flutter test` fixes to false; without the seam
  /// this branch could not be covered at all.
  factory AoidSession.deviceKeychain({
    required String accessToken,
    required String refreshToken,
    bool isWeb = kIsWeb,
  }) {
    if (isWeb) {
      throw UnsupportedError(
        'Mode B (refresh token in the device keychain) is native-only. On web '
        'there is no keychain: flutter_secure_storage_web keeps the ciphertext '
        'and its AES key together in window.localStorage, so the token is '
        'readable by any XSS — the configuration 50-CONTEXT.md D4 forbids. '
        'Use AoidSession.backendHeldCookie (Mode A) on web.',
      );
    }
    return AoidSession._(
      posture: AoidRefreshTokenPosture.deviceKeychain,
      accessToken: accessToken,
      refreshToken: refreshToken,
      isWeb: isWeb,
    );
  }

  /// Where this session's refresh token lives.
  final AoidRefreshTokenPosture posture;

  /// The bearer access token, when the posture has one. Null for Mode C.
  final String? accessToken;

  /// The refresh token **held by this client**, or null when it is held by a
  /// backend (Mode A) or does not exist (Mode C).
  ///
  /// Only [AoidSession.deviceKeychain] can set this, and it refuses to build a
  /// web session — so this is null in every web configuration.
  final String? refreshToken;

  /// The platform this session was built for. Recorded so a consumer can
  /// reason about custody without re-deriving it from `kIsWeb`.
  final bool isWeb;

  /// True only when a refresh token is held **by this client**.
  ///
  /// Always false on web (D4): [refreshToken] is only settable by
  /// [AoidSession.deviceKeychain], which throws rather than build a web
  /// session. Mode A and Mode C are false on every platform — the token lives
  /// on the app's backend or does not exist. Mode B is true on native.
  bool get hasClientHeldRefreshToken => refreshToken != null;
}
