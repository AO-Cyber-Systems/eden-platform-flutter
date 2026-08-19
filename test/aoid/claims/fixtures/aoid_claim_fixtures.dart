// HAND-BUILT AOID token fixtures.
//
// Every token below is assembled here, in Dart, from a literal payload map. No
// token was copied from a real AOID deployment and none was generated. The
// signature segment is a fixed, meaningless literal: the client NEVER verifies
// an AOID signature (that is the server's job — see
// eden-biz/go/internal/aoidverify/direct_verifier.go), so a real signature
// would imply a guarantee the SDK does not make.
//
// Payload shapes mirror aoid the token claims
//   AccessTokenClaims — iss sub aud exp iat jti + tnt scope client_id aal ent
//   IDTokenClaims     — iss sub aud exp iat     + tnt nonce email email_verified name
//
// THE POINT OF THE PAIR. `accessTokenSwitchedToTenantB` and `idTokenHomeTenant`
// describe the SAME identity at the SAME moment, after a switch to tenant B:
//
//   access token tnt -> 'globex'                              (tenant B's SLUG)
//   id_token     tnt -> '018f3a2b-4c5d-4e6f-8a9b-0c1d2e3f4a5b' (HOME tenant UUID)
//
// `accessTokenNoActiveSelection` is the other half of the story and is NOT
// optional: with no active tenant selected the access token's tnt is the HOME
// tenant's SLUG ('acme') for GID-14 byte-compat. Without it, the switched
// fixture reads as "the two values always differ", which is false. What is
// always true is that one is a SLUG and the other is a UUID.

import 'dart:convert';

/// The home tenant's operator-friendly slug. Appears on the ACCESS token when
/// no other tenant is selected. Never appears on the id_token.
const String homeTenantSlug = 'acme';

/// The home tenant's UUID. Appears on the ID token's `tnt`, always, regardless
/// of which tenant is active. Never appears on the access token.
const String homeTenantUuid = '018f3a2b-4c5d-4e6f-8a9b-0c1d2e3f4a5b';

/// The switch target's slug. Appears on the ACCESS token after a switch.
const String tenantBSlug = 'globex';

/// The switch target's UUID — present only to prove it never reaches a token.
const String tenantBUuid = '018f4c7d-9e0f-4a1b-8c2d-3e4f5a6b7c8d';

/// `sub` — the GLOBAL `identities.id` (GID-13). Independent of the tenant axis;
/// identical on both tokens.
const String identitySubject = '7f3c1d9e-2b4a-4f6d-9c8e-1a2b3c4d5e6f';

const String issuer = 'https://auth.aocyber.ai';
const String clientId = 'aodex-flutter';

/// 2030-01-01T00:00:00Z. Far future so a test never depends on wall-clock time
/// — and irrelevant either way, because `JWT.decode` does not check expiry.
const int expEpochSeconds = 1893456000;
const int iatEpochSeconds = 1893452400;

/// A distinctive string embedded in the malformed fixtures.
///
/// It stands in for real token material. If it ever appears in a thrown error's
/// message, that error would carry token bytes into a log. The base64 decoder
/// underneath `JWT.decode` throws a `FormatException` that quotes its input,
/// and `JWTUndefinedException` wraps `ex.toString()` verbatim — so this leak is
/// one careless rethrow away, not hypothetical.
const String secretMarker = 'SUPERSECRETTOKENMATERIAL';

String _b64UrlNoPad(String s) =>
    base64Url.encode(utf8.encode(s)).replaceAll('=', '');

/// Assembles `<header>.<payload>.<signature>` with unpadded base64url segments,
/// the same encoding `lib/src/aoid/pkce.dart` uses for the PKCE verifier.
String buildJwt(Map<String, Object?> payload) {
  final header = _b64UrlNoPad(
    jsonEncode({'alg': 'RS256', 'typ': 'JWT', 'kid': 'aoid-test-key'}),
  );
  final body = _b64UrlNoPad(jsonEncode(payload));
  // Deliberately not a signature. The client cannot verify one.
  final signature = _b64UrlNoPad('unverifiable-by-design');
  return '$header.$body.$signature';
}

Map<String, Object?> _accessPayload({required String tnt}) => {
  'iss': issuer,
  'sub': identitySubject,
  'aud': clientId,
  'exp': expEpochSeconds,
  'iat': iatEpochSeconds,
  'jti': 'a1b2c3d4-0000-4000-8000-000000000001',
  'tnt': tnt,
  'scope': 'openid profile aodex.read',
  'client_id': clientId,
  'aal': 'aal2',
  'ent': ['tenant.admin', 'aodex.user'],
};

/// ACCESS token issued after the user switched to tenant B.
/// `tnt` is tenant B's **SLUG**.
final String accessTokenSwitchedToTenantB = buildJwt(
  _accessPayload(tnt: tenantBSlug),
);

/// ACCESS token with no active tenant selected.
/// `tnt` is the HOME tenant's **SLUG** (GID-14 byte-compat) — still a slug.
final String accessTokenNoActiveSelection = buildJwt(
  _accessPayload(tnt: homeTenantSlug),
);

/// ID token for the same identity, at the same moment as
/// [accessTokenSwitchedToTenantB]. `tnt` is the HOME tenant's **UUID** and does
/// not follow the switch.
final String idTokenHomeTenant = buildJwt({
  'iss': issuer,
  'sub': identitySubject,
  'aud': clientId,
  'exp': expEpochSeconds,
  'iat': iatEpochSeconds,
  'tnt': homeTenantUuid,
  'nonce': 'n-0S6_WzA2Mj',
  'email': 'ada@acme.example',
  'email_verified': true,
  'name': 'Ada Lovelace',
});

/// ACCESS token with every optional claim (`aal`, `ent`) omitted, exactly as Go
/// emits for a machine token — both carry `omitempty`.
final String accessTokenWithoutOptionalClaims = buildJwt({
  'iss': issuer,
  'sub': identitySubject,
  'aud': clientId,
  'exp': expEpochSeconds,
  'iat': iatEpochSeconds,
  'tnt': homeTenantSlug,
  'scope': 'openid',
  'client_id': clientId,
});

/// ID token with the optional profile claims omitted (`omitempty` on the Go
/// side too).
final String idTokenWithoutProfileClaims = buildJwt({
  'iss': issuer,
  'sub': identitySubject,
  'aud': clientId,
  'exp': expEpochSeconds,
  'iat': iatEpochSeconds,
  'tnt': homeTenantUuid,
});

/// Structurally a JWT, but the payload segment is not valid base64url — the `@`
/// characters are outside the alphabet. Decoding throws a `FormatException`
/// that quotes the offending input, which is how token material leaks into an
/// error message.
final String malformedToken =
    '${_b64UrlNoPad(jsonEncode({'alg': 'RS256', 'typ': 'JWT'}))}'
    '.@@@$secretMarker@@@'
    '.${_b64UrlNoPad('unverifiable-by-design')}';

/// Not a JWT at all — no segment separators.
const String notAJwtAtAll = 'this-is-not-a-jwt-$secretMarker';

/// Valid JWT, valid JSON payload, but no `tnt` claim.
final String accessTokenMissingTenantClaim = buildJwt({
  'iss': issuer,
  'sub': identitySubject,
  'exp': expEpochSeconds,
  'client_id': clientId,
  'scope': 'openid',
});

/// Valid JWT whose `tnt` is a number rather than a string.
final String accessTokenWithNonStringTenant = buildJwt({
  'iss': issuer,
  'sub': identitySubject,
  'exp': expEpochSeconds,
  'client_id': clientId,
  'tnt': 42,
});
