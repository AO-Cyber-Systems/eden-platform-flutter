// AoidTokenStore — the AOID module's token-persistence seam, and the
// refresh-token custody vocabulary the rest of the module speaks.
//
// RIVERPOD-FREE BY CONSTRUCTION. Reachable from
// `package:eden_platform_flutter/aoid.dart` via lib/src/aoid/parts/storage.dart,
// whose transitive closure test/aoid/riverpod_free_gate_test.dart walks. Do not
// add an import here that reaches flutter_riverpod.
//
// NO DEPENDENCY ON flutter_secure_storage — deliberately. This package pins
// that plugin to 9.2.4 EXACTLY (pubspec.yaml: "DO NOT bump to 10.x, upstream
// issue #1043 data-loss bug"), while AODex — objective 50's proving consumer —
// carries a dependency_overrides entry resolving ^10.0.0. Depending on the
// abstract TokenStorage interface (lib/src/auth/token_storage.dart) and letting
// the consumer inject an implementation means those two pins never have to be
// reconciled. See 50-RESEARCH.md §5.4.

/// WHERE a session's refresh token lives.
///
/// This is the narrow custody question 50-CONTEXT.md **D4** answers, and it is
/// deliberately narrower than "deployment mode": TRD 50-09 owns the full mode
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
/// D4 forbids and premise correction C3 records as having shipped; TRD 50-02
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
/// structural — see 50-CONTEXT.md D4 and premise correction C3.
///
/// Pick an implementation with `aoidTokenStoreFor` rather than by hand; it is
/// the single seam TRD 50-09 (deployment modes) and 50-13 (tenant switch)
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
