// R-ACL-03 hand-built AOID test fixtures.
//
// Per the global TDD playbook habit #4 ("Fixture generators, not
// LLM-generated test data"): every value below is either a well-known
// published test vector (RFC 7636 Appendix B) or computed deterministically
// from explicit, hand-authored claims/fields — never invented free-form by
// an LLM. There is no live AOID service to record a VCR-style cassette
// against, so this file + fake_aoid_endpoint.dart together stand in for
// that recording: a committed, deterministic contract double.

import 'dart:convert';

/// A single PKCE (RFC 7636, S256) material set for tests, paired with the
/// CSRF `state` a fake authorize step should echo back.
///
/// The verifier/challenge pair is the RFC 7636 Appendix B known-answer
/// vector — the SAME fixed pair used by `pkce_generator_test.dart`. Hand
/// copied, do NOT regenerate.
class PkceFixture {
  const PkceFixture({
    required this.codeVerifier,
    required this.codeChallenge,
    required this.state,
  });

  final String codeVerifier;
  final String codeChallenge;
  final String state;
}

/// RFC 7636 Appendix B known-answer PKCE pair + a fixed fixture `state`.
///
/// NOTE: `AoidOidcAuthStrategy` always sources its PKCE material from
/// `PkceGenerator.generate()` (secure randomness) rather than this fixture
/// directly — `PkceGenerator` has no public constructor to inject a fixed
/// pair. This fixture exists for fixture-shape tests and documents the
/// known-answer vector this fixture set is built around.
PkceFixture pkceFixture() => const PkceFixture(
      codeVerifier: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
      codeChallenge: 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      state: 'fixture-state-9f3ac71c2e4d5b80',
    );

/// Unpadded base64url segment for a hand-authored JWT header/payload map.
String _jwtSegment(Map<String, Object?> claims) =>
    base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');

/// Builds a static, ES256-*shaped* (not actually signed/verifiable) JWT
/// string: `header.payload.sig`. Every claim is hand-specified below per
/// the AOID frozen contract §1 response shape — this is a fixture
/// generator, not randomly-generated test data.
String _fixtureJwt({required String sub, required String jti}) {
  const header = {'alg': 'ES256', 'typ': 'JWT'};
  final payload = {
    'iss': 'https://auth.aocyber.ai',
    'sub': sub,
    'aud': 'eden-biz-console',
    'exp': 1900000000,
    'iat': 1899999400,
    'jti': jti,
    'tnt': 'tenant-fixture-001',
    'scope': 'openid profile email offline_access',
    'client_id': 'eden-biz-console',
    'aal': 'aal1',
    'ent': <String>[],
  };
  return '${_jwtSegment(header)}.${_jwtSegment(payload)}.'
      'fixture-signature-not-valid-do-not-verify';
}

/// Default fixture access token (a fresh, hand-specified fixture JWT).
String fixtureAccessToken() =>
    _fixtureJwt(sub: 'user-fixture-001', jti: 'fixture-jwt-access-001');

/// Default fixture refresh token. Refresh tokens are opaque at AOID (not
/// JWTs) so this is a plain fixed fixture string, not a JWT shape.
String fixtureRefreshToken() => 'fixture-refresh-token-001';

/// Default fixture id_token (fixture JWT, distinct jti from the access
/// token so tests can tell them apart if both are asserted).
String fixtureIdToken() =>
    _fixtureJwt(sub: 'user-fixture-001', jti: 'fixture-jwt-id-001');

/// A successful AOID `/oauth/token` response body (frozen contract §1):
/// `access_token`, `refresh_token`, `id_token`, `expires_in`.
Map<String, Object?> aoidTokenResponse({
  String? accessToken,
  String? refreshToken,
  String? idToken,
  int expiresIn = 3600,
}) =>
    {
      'access_token': accessToken ?? fixtureAccessToken(),
      'refresh_token': refreshToken ?? fixtureRefreshToken(),
      'id_token': idToken ?? fixtureIdToken(),
      'expires_in': expiresIn,
    };

/// An AOID error response body for a non-200 `/oauth/token` (or
/// `/oauth/revoke`) response, shaped like a standard OAuth2 error.
Map<String, Object?> aoidErrorResponse(int status) => {
      'error': status == 400 ? 'invalid_grant' : 'server_error',
      'error_description':
          'fixture error response for status $status (aoid_fixtures.dart)',
    };
