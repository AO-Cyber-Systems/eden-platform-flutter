// THE THREE AOID DEPLOYMENT MODES, and the ONE selector.
//
// Reachable from `package:eden_platform_flutter/eden_platform.dart` via
// lib/src/aoid/parts/modes.dart.
//
// HISTORY: this file was riverpod-free by ENFORCED invariant, because
// `lib/aoid.dart` was a riverpod-free barrel that a riverpod-3 consumer had to
// be able to import while this package was still on riverpod 2. That version
// boundary is gone, the barrel was folded into
// eden_platform.dart by the spec, and the closure-walking gate that enforced
// it was deleted with it. The file still names no riverpod symbol, which is
// worth keeping on its own merits — but it is now a preference, not a gate.
//
// ## Where the web refusal lives — READ BEFORE EDITING
//
// There is NO `if (isWeb)` in this file, and adding one is a regression even if
// it is correct. Mode B on web is refused by CONSTRUCTING the spec
// `AoidSecureTokenStore`, whose constructor throws on web. That keeps the D4
// refusal in exactly ONE place. A second, independent check here would drift
// out of sync with it the first time either is edited, and the drift is silent:
// two guards that disagree still both compile.
//
// `isWeb` appears below only as a parameter being PASSED THROUGH to the spec
// guards, never as a branch condition.

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../auth/token_storage.dart';
import '../../models/platform_models.dart';
import '../aoid_session.dart';
import '../claims/aoid_claims.dart';
import '../storage/aoid_memory_token_store.dart';
import '../storage/aoid_secure_token_store.dart';
import '../storage/aoid_token_store.dart';

/// The three AOID deployment modes, **ranked**.
///
/// The refresh token is the asset. Ranked posture:
///   1. [bff]        — refresh token never reaches the client at all.
///   2. [sameOrigin] — nothing to hold; the session is cookie-bound.
///   3. [publicPkce] — NATIVE ONLY; refresh token in the OS keychain.
///   (4. refresh token in web localStorage — FORBIDDEN, and what this
///       package shipped until the issuer. Not representable here.)
///
/// The absent fourth value is the point. Premise correction C3 records that
/// configuration as having SHIPPED, readable by any XSS on the eden-biz
/// console. the spec removed the capability rather than adding a flag that
/// discourages it; this enum has no way to name it.
enum AoidDeploymentMode {
  /// **Mode A — BFF / confidential client. The default for web.**
  ///
  /// The SDK obtains an authorization code and hands it, with the
  /// `code_verifier`, to the **consuming app's own backend**. That backend
  /// holds the client secret, performs the confidential exchange with AOID, and
  /// sets an httpOnly `SameSite` cookie. The client never sees a refresh token
  /// at all — see `AoidCodeSink`.
  ///
  /// This is the mode AODex needs: its AOID client is CONFIDENTIAL
  /// (its server configuration hard-requires
  /// `AOID_CLIENT_SECRET`), so a public-client Mode B would require a second
  /// client registered in AOID with its own `client_id` and redirect URIs.
  bff,

  /// **Mode B — public client + PKCE. NATIVE ONLY.**
  ///
  /// The refresh token lives in the OS keychain. Selecting this on web throws;
  /// see this file's header for where that refusal lives.
  publicPkce,

  /// **Mode C — same-origin, cookie-bound.**
  ///
  /// For apps served from AOID's own origin, portal-style. No refresh token
  /// exists client-side because the session is the cookie.
  sameOrigin,
}

/// D4's custody mapping, and its ranking.
extension AoidDeploymentModeCustody on AoidDeploymentMode {
  /// Where this mode's refresh token lives.
  ///
  /// This MAPS onto [AoidRefreshTokenPosture] rather than replacing
  /// it, so there is one custody vocabulary in the module, not two.
  AoidRefreshTokenPosture get posture => switch (this) {
    AoidDeploymentMode.bff => AoidRefreshTokenPosture.backendHeldCookie,
    AoidDeploymentMode.publicPkce => AoidRefreshTokenPosture.deviceKeychain,
    AoidDeploymentMode.sameOrigin => AoidRefreshTokenPosture.none,
  };

  /// D4's ranking, 1 = most preferred. Documentation made checkable.
  int get d4Rank => switch (this) {
    AoidDeploymentMode.bff => 1,
    AoidDeploymentMode.sameOrigin => 2,
    AoidDeploymentMode.publicPkce => 3,
  };

  /// Whether this mode is selectable at all on web.
  ///
  /// **Documentation only — this is NOT the guard.** Nothing in this library
  /// branches on it; the refusal is `AoidSecureTokenStore`'s constructor. It
  /// exists so a consumer can present a mode picker without provoking a throw,
  /// and it is asserted against the real refusal by the matrix test, so the two
  /// cannot drift apart into a comforting lie.
  bool get isSelectableOnWeb => this != AoidDeploymentMode.publicPkce;
}

/// What a deployment mode resolves to: the token store, and the session shape.
///
/// Returned by [aoidWiringFor], which is the module's SINGLE mode-selection
/// point. Anything that needs to know "which store, which session" asks here,
/// so there is one place a mode can be got wrong.
final class AoidModeWiring {
  const AoidModeWiring._({
    required this.mode,
    required this.tokenStore,
    required this.session,
  });

  /// The mode this wiring was selected for.
  final AoidDeploymentMode mode;

  /// The store this deployment persists tokens through.
  final AoidTokenStore tokenStore;

  /// The session shape this deployment produces.
  final AoidSession session;

  /// True only when the refresh token is held **by this client**. True in
  /// exactly one of the six mode x platform cells: [AoidDeploymentMode
  ///.publicPkce] on native.
  bool get hasClientHeldRefreshToken => session.hasClientHeldRefreshToken;

  /// True for Modes A and C, on every platform.
  bool get isCookieBound => session.cookieBound;
}

/// Resolves [mode] and the platform to a token store and a session shape.
///
/// **THE single mode-selection point.** There is no `if (isWeb)` here — see
/// this file's header. Mode B on web is refused by the spec
/// [AoidSecureTokenStore] constructor, which throws [UnsupportedError] citing
/// D4.
///
/// | mode | native | web |
/// |---|---|---|
/// | [AoidDeploymentMode.bff] | memory store, cookie-bound session | same |
/// | [AoidDeploymentMode.sameOrigin] | memory store, cookie-bound session | same |
/// | [AoidDeploymentMode.publicPkce] | secure store, keychain session | **THROWS** |
///
/// [isWeb] defaults to [kIsWeb] and is injectable for the reason every other
/// constructor in this module takes it: `kIsWeb` is a compile-time constant and
/// `flutter test` is never web, so a `kIsWeb`-gated branch is otherwise
/// uncoverable. Precedent: `connectCookieInterceptorWebForTest`
/// (lib/src/networking/connect_cookie_interceptor.dart:63-67).
///
/// Throws:
/// - [UnsupportedError] for [AoidDeploymentMode.publicPkce] when [isWeb] is
///   true and a delegate was supplied — the spec guard, citing D4.
/// - [ArgumentError] for [AoidDeploymentMode.publicPkce] when
///   [nativeSecureStorage], [accessToken] or [refreshToken] is missing. Mode B
///   is not selectable without them **on any platform**, so this is a refusal
///   too, never a downgrade to a weaker mode.
AoidModeWiring aoidWiringFor({
  required AoidDeploymentMode mode,
  bool isWeb = kIsWeb,
  TokenStorage? nativeSecureStorage,
  String? accessToken,
  String? refreshToken,
  AoidAccessClaims? accessClaims,
  AoidIdClaims? idClaims,
}) {
  switch (mode) {
    case AoidDeploymentMode.publicPkce:
      // The store is built FIRST, and its constructor IS this function's web
      // refusal. Do not hoist an `if (isWeb)` above it "to give a better
      // message" — that is a second guard, and the spec already names D4 and
      // the remedy.
      final delegate = nativeSecureStorage;
      if (delegate == null) {
        throw ArgumentError.value(
          null,
          'nativeSecureStorage',
          'Mode B (publicPkce) needs a TokenStorage delegate for the OS '
              'keychain. It is not supplied a default and it does not fall '
              'back to an in-memory store: a silent downgrade produces a '
              'native session that mysteriously stops restoring. On web Mode B '
              'is refused outright — see AoidSecureTokenStore and '
              'the design notes.',
        );
      }
      // Throws UnsupportedError on web. THE refusal.
      final store = AoidSecureTokenStore(delegate, isWeb: isWeb);

      if (accessToken == null || refreshToken == null) {
        throw ArgumentError(
          'Mode B (publicPkce) is the only mode that carries tokens on the '
          'client; both accessToken and refreshToken are required.',
        );
      }
      return AoidModeWiring._(
        mode: mode,
        tokenStore: store,
        // Throws on web too — a second the spec guard on the session side, not a
        // second CONDITION: both are `isWeb` checks living in the spec files.
        session: AoidSession.deviceKeychain(
          accessToken: accessToken,
          refreshToken: refreshToken,
          isWeb: isWeb,
          accessClaims: accessClaims,
          idClaims: idClaims,
        ),
      );

    case AoidDeploymentMode.bff:
      return AoidModeWiring._(
        mode: mode,
        // Mode A holds no refresh token on ANY platform — the app's backend
        // does. `AoidMemoryTokenStore.writeRefreshToken` throws on a non-null
        // value, so a Mode A wiring that starts persisting one fails loudly.
        tokenStore: AoidMemoryTokenStore(),
        session: AoidSession.backendHeldCookie(
          accessToken: accessToken,
          isWeb: isWeb,
          accessClaims: accessClaims,
          idClaims: idClaims,
        ),
      );

    case AoidDeploymentMode.sameOrigin:
      return AoidModeWiring._(
        mode: mode,
        tokenStore: AoidMemoryTokenStore(),
        session: AoidSession.sameOriginCookie(
          isWeb: isWeb,
          accessClaims: accessClaims,
          idClaims: idClaims,
        ),
      );
  }
}

/// Bridges an [AoidSession] onto eden's existing [PlatformSession].
///
/// Modes A and C become `PlatformSession.cookieBound`
/// (platform_models.dart:109-115) rather than a parallel session type, so
/// `AuthNotifier._applyAuthResult` **already** skips `_persistTokens` for them
/// (auth_provider.dart:184-186, whose comment explains that persisting the
/// empty strings would clobber real values). Both modes therefore ride tested
/// behaviour instead of forking it.
extension AoidSessionPlatformBridge on AoidSession {
  /// Converts to a [PlatformSession].
  ///
  /// [role] is whatever the CONSUMING APP decides a role is. It is never
  /// derived from a claim: the AOID portal's strategy passes `role: me.aal`
  /// (`the portal strategy`), and an
  /// assurance level is not a role. AOID owns authN; the app owns authZ
  ///. Institutionalising that overload in the
  /// shared module would push an authZ decision into the identity layer for
  /// every consumer at once.
  PlatformSession toPlatformSession({
    required PlatformUser user,
    String? companyId,
    String? role,
  }) {
    if (cookieBound) {
      return PlatformSession.cookieBound(
        user: user,
        companyId: companyId,
        role: role,
      );
    }
    return PlatformSession(
      accessToken: accessToken ?? '',
      refreshToken: refreshToken ?? '',
      user: user,
      companyId: companyId,
      role: role,
    );
  }
}
