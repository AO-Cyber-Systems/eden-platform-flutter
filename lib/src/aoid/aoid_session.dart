// AoidSession — just enough session to carry refresh-token custody honestly.
//
// RIVERPOD-FREE BY CONSTRUCTION (see storage/aoid_token_store.dart's header).
//
// the spec built the custody dimension. the spec COMPLETED the mode
// dimension, adding — additively, without changing any the spec behaviour — the
// deployment [mode], the [cookieBound] flag, and the AOID claims as
// FIRST-CLASS FIELDS.
//
// The claims are two fields, not one. the portal's own strategy
//.dart:65,223-226` hangs AOID claims off the session with an `Expando`
// side-table: invisible to the type system, and it dies with the session
// object. That pattern is deliberately NOT copied here. Neither is that file's
// `role: me.aal` overload — an assurance level is not a role, and the shared
// module must not institutionalise the conflation.
//
// There is deliberately no single `claims` field either: the spec (D5) keeps
// AoidAccessClaims and AoidIdClaims apart precisely so the access token's `tnt`
// (ACTIVE tenant SLUG) and the id_token's `tnt` (HOME tenant UUID) cannot meet
// at a common type. A unified field here would rebuild that meeting point.

import 'package:flutter/foundation.dart' show kIsWeb;

import 'claims/aoid_claims.dart';
import 'mode/aoid_deployment_mode.dart';
import 'storage/aoid_token_store.dart';

/// An AOID session, carrying the one property this the spec exists to make
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
    required this.accessClaims,
    required this.idClaims,
  });

  /// **Mode A — BFF / confidential client.** The app's own backend holds the
  /// refresh token; this client got an httpOnly `SameSite` cookie. The default
  /// posture for web.
  ///
  /// Takes no refresh token: there is nothing to pass, on any platform.
  factory AoidSession.backendHeldCookie({
    String? accessToken,
    bool isWeb = kIsWeb,
    AoidAccessClaims? accessClaims,
    AoidIdClaims? idClaims,
  }) => AoidSession._(
    posture: AoidRefreshTokenPosture.backendHeldCookie,
    accessToken: accessToken,
    refreshToken: null,
    isWeb: isWeb,
    accessClaims: accessClaims,
    idClaims: idClaims,
  );

  /// **Mode C — same-origin.** Nothing is held; the session is bound to a
  /// cookie issued by AOID's own origin. Neither token is meaningful.
  factory AoidSession.sameOriginCookie({
    bool isWeb = kIsWeb,
    AoidAccessClaims? accessClaims,
    AoidIdClaims? idClaims,
  }) => AoidSession._(
    posture: AoidRefreshTokenPosture.none,
    accessToken: null,
    refreshToken: null,
    isWeb: isWeb,
    accessClaims: accessClaims,
    idClaims: idClaims,
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
    AoidAccessClaims? accessClaims,
    AoidIdClaims? idClaims,
  }) {
    if (isWeb) {
      throw UnsupportedError(
        'Mode B (refresh token in the device keychain) is native-only. On web '
        'there is no keychain: flutter_secure_storage_web keeps the ciphertext '
        'and its AES key together in window.localStorage, so the token is '
        'readable by any XSS — the configuration the design notes forbids. '
        'Use AoidSession.backendHeldCookie (Mode A) on web.',
      );
    }
    return AoidSession._(
      posture: AoidRefreshTokenPosture.deviceKeychain,
      accessToken: accessToken,
      refreshToken: refreshToken,
      isWeb: isWeb,
      accessClaims: accessClaims,
      idClaims: idClaims,
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

  /// The AOID **access token's** claims, when they have been decoded.
  ///
  /// Its `tnt` is the ACTIVE tenant SLUG. Kept separate from [idClaims] on
  /// purpose — see this file's header and the design notes.
  final AoidAccessClaims? accessClaims;

  /// The AOID **id_token's** claims, when present and decoded.
  ///
  /// Its `tnt` is the HOME tenant UUID and does NOT follow the active tenant.
  final AoidIdClaims? idClaims;

  /// Which the design notes **D4 deployment mode** produced this session.
  ///
  /// DERIVED from [posture] rather than stored. A stored field would be a
  /// second source of truth for the same fact, and the two could disagree —
  /// a session claiming Mode A while holding a keychain refresh token is
  /// exactly the state D4 exists to make unrepresentable.
  AoidDeploymentMode get mode => switch (posture) {
    AoidRefreshTokenPosture.backendHeldCookie => AoidDeploymentMode.bff,
    AoidRefreshTokenPosture.deviceKeychain => AoidDeploymentMode.publicPkce,
    AoidRefreshTokenPosture.none => AoidDeploymentMode.sameOrigin,
  };

  /// True when authentication rides a cookie rather than a client-held token
  /// pair — Modes A and C, on every platform.
  ///
  /// This is the flag that decides which `PlatformSession` constructor a
  /// session becomes (see `AoidSessionPlatformBridge.toPlatformSession`), and
  /// therefore whether `AuthNotifier._applyAuthResult` skips `_persistTokens`
  /// (auth_provider.dart:184-186). Modes A and C ride that existing, tested
  /// skip; they do not fork session handling.
  ///
  /// Derived, for the same reason [mode] is: `cookieBound == true` together
  /// with a client-held refresh token is a contradiction that must not be
  /// constructible.
  bool get cookieBound => posture != AoidRefreshTokenPosture.deviceKeychain;

  /// True only when a refresh token is held **by this client**.
  ///
  /// Always false on web (D4): [refreshToken] is only settable by
  /// [AoidSession.deviceKeychain], which throws rather than build a web
  /// session. Mode A and Mode C are false on every platform — the token lives
  /// on the app's backend or does not exist. Mode B is true on native.
  bool get hasClientHeldRefreshToken => refreshToken != null;
}
