// The SINGLE source of AOID URL construction for this module.
//
// the spec (native ceremony) and the spec (tenant switch) both build on this; two
// URL builders would guarantee drift. AoidOidcAuthStrategy still has its own
// inline `Uri.parse('$issuer/oauth/authorize')` getters — those predate this
// type and are left alone here because this the spec changes no behaviour; folding
// them onto AoidEndpoints belongs to the spec that next touches that file.
//
// Paths are AOID's, per the issuer router.
//
// RIVERPOD-FREE: reachable from lib/aoid.dart. Dependency-free by design (D1
// — every eden consumer pays for anything added here), so it imports nothing
// at all rather than pulling package:meta for a single @immutable annotation.

/// Derives every AOID OAuth endpoint from an issuer origin.
///
/// ```dart
/// final e = AoidEndpoints(Uri.parse('https://auth.aocyber.ai'));
/// e.token; // https://auth.aocyber.ai/oauth/token
/// ```
///
/// Paths are resolved absolutely against the issuer's origin, so an issuer
/// carrying a trailing path segment does not silently produce nested URLs.
class AoidEndpoints {
  const AoidEndpoints(this.issuer);

  /// Convenience for the common `String` form, e.g. `https://auth.aocyber.ai`.
  AoidEndpoints.parse(String issuer) : issuer = Uri.parse(issuer);

  /// AOID issuer origin, e.g. `https://auth.aocyber.ai`.
  final Uri issuer;

  /// `{issuer}/oauth/authorize` — authorization-code + PKCE entry point.
  Uri get authorize => issuer.resolve('/oauth/authorize');

  /// `{issuer}/oauth/token` — code exchange and refresh grant.
  Uri get token => issuer.resolve('/oauth/token');

  /// `{issuer}/oauth/revoke` — best-effort refresh-token revocation.
  Uri get revoke => issuer.resolve('/oauth/revoke');

  /// `{issuer}/oauth/native/start` — the issuer no-redirect ceremony,
  /// step 1.
  Uri get nativeStart => issuer.resolve('/oauth/native/start');

  /// `{issuer}/oauth/native/verify` — the issuer no-redirect ceremony,
  /// step 2.
  Uri get nativeVerify => issuer.resolve('/oauth/native/verify');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AoidEndpoints &&
          runtimeType == other.runtimeType &&
          issuer == other.issuer);

  @override
  int get hashCode => issuer.hashCode;

  @override
  String toString() => 'AoidEndpoints($issuer)';
}
