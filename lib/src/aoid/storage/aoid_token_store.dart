// AoidTokenStore — the AOID module's token-persistence seam, and the
// refresh-token custody vocabulary the rest of the module speaks.
//
// Reachable from `package:eden_platform_flutter/eden_platform.dart` via
// lib/src/aoid/parts/storage.dart.
//
// HISTORY: this file was riverpod-free by ENFORCED invariant, because
// `lib/aoid.dart` was a riverpod-free barrel a riverpod-3 consumer had to be
// able to import while this package was still on riverpod 2. That version
// boundary is gone, the barrel was folded into
// eden_platform.dart, and the closure-walking gate went with it.
// The file still names no riverpod symbol; that is now a preference, not a gate.
//
// NO DEPENDENCY ON flutter_secure_storage — deliberately. This package pins
// that plugin to 9.2.4 EXACTLY (pubspec.yaml: "DO NOT bump to 10.x, upstream
// issue #1043 data-loss bug"), while AODex — the issuer proving consumer —
// carries a dependency_overrides entry resolving ^10.0.0. Depending on the
// abstract TokenStorage interface (lib/src/auth/token_storage.dart) and letting
// the consumer inject an implementation means those two pins never have to be
// reconciled. See the design notes §5.4.

/// WHERE a session's refresh token lives.
///
/// This is the narrow custody question the design notes **D4** answers, and it is
/// deliberately narrower than "deployment mode": the mode layer owns the full mode
/// matrix (`lib/src/aoid/parts/modes.dart`) and will map its deployment modes
/// onto these three postures rather than replacing them.
///
/// | D4 mode | posture | refresh token lives |
/// |---|---|---|
/// | A — BFF / confidential | [backendHeldCookie] | the app's own backend; the client gets an httpOnly SameSite cookie |
/// | B — public + PKCE | [deviceKeychain] | the OS keychain, on **native only** |
/// | C — same-origin | [none] | nowhere; the session is cookie-bound |
///
/// There is no fourth value for "web localStorage". That is the configuration
/// D4 forbids and premise correction C3 records as having shipped; the token store
/// removed the capability rather than adding a flag to discourage it.
enum AoidRefreshTokenPosture {
  /// **Mode A.** The app's own backend holds the refresh token and hands the
  /// client an httpOnly `SameSite` cookie. The default posture for web.
  backendHeldCookie,

  /// **Mode B.** This client holds the refresh token in the OS keychain.
  /// **Native only** — [AoidSecureTokenStore] refuses to construct on web and
  /// `AoidSession.deviceKeychain` refuses to build a web session.
  deviceKeychain,

  /// **Mode C.** No refresh token exists anywhere; the session is bound to a
  /// same-origin cookie issued by AOID itself.
  none,
}

/// Token persistence for the AOID module.
///
/// The refresh token is the asset D4 protects. On web there is **no**
/// implementation of this interface that can persist one:
/// [AoidMemoryTokenStore] throws from [writeRefreshToken] and
/// [AoidSecureTokenStore] refuses to construct. That is deliberate and
/// structural — see the design notes and premise correction C3.
///
/// Pick an implementation with `aoidTokenStoreFor` rather than by hand; it is
/// the single seam the deployment-mode and tenant-switch layers
/// extend.
abstract class AoidTokenStore {
  /// The persisted access token, or `null` if none.
  Future<String?> readAccessToken();

  /// Persists the access token, or clears it when [value] is `null`.
  Future<void> writeAccessToken(String? value);

  /// Persists the refresh token, or clears it when [value] is `null`.
  ///
  /// **Throws [UnsupportedError] on any web-capable store when [value] is
  /// non-null.** Passing `null` MUST always succeed on every implementation —
  /// logout and best-effort clearing depend on it.
  Future<void> writeRefreshToken(String? value);

  /// The persisted refresh token, or `null`. Always `null` for stores that
  /// cannot hold one.
  Future<String?> readRefreshToken();

  /// Drops every token this store holds.
  Future<void> clear();
}
