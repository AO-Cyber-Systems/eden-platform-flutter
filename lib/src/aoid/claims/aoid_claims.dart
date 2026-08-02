// The two AOID token claim sets, decoded WITHOUT verification.
//
// Two decoders, two result types, NO meeting point. There is deliberately no
// `AoidClaims` type and no shared `tnt` accessor: if the two `tnt` values could
// meet at a common type, the whole point of `tenant_ref.dart` would be gone.
// `AoidAccessClaims` can only produce an [AoidActiveTenantSlug] and
// `AoidIdClaims` can only produce an [AoidHomeTenantId], so decoding the wrong
// token cannot silently type-check downstream.
//
// If you find yourself wanting a unified type "for convenience", that is the
// bug asking to be reintroduced. See tenant_ref.dart's header and AOID
// objective 50, D5.
//
// Decoding uses `JWT.decode` from `dart_jsonwebtoken`, already a dependency and
// already used for exactly this purpose at
// lib/src/networking/proactive_refresh.dart:80 (scheduling on `exp`). No new
// dependency is needed and none must be added: pulling in `jose` or
// `openid_client` to verify client-side would be a promise this package cannot
// keep.
//
// Riverpod-free and Flutter-free by construction — this file lands inside
// lib/aoid.dart's transitive closure, which
// test/aoid/riverpod_free_gate_test.dart walks and enforces.

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

import 'tenant_ref.dart';

/// Thrown when a token cannot be decoded into the expected claim set.
///
/// Carries a [reason] built from LITERALS AND CLAIM NAMES ONLY — never from the
/// token, a claim value, or the underlying exception's message.
///
/// That restriction is load-bearing, not stylistic. The base64 decoder beneath
/// `JWT.decode` throws a `FormatException` that quotes its input, and
/// `JWTUndefinedException` wraps `ex.toString()` verbatim. Rethrowing the cause,
/// or interpolating it into a message, would carry token bytes into every log
/// sink the app has. Pinned by
/// `test/aoid/claims/aoid_claims_test.dart`'s "leaks nothing" group.
final class AoidClaimsFormatException implements Exception {
  const AoidClaimsFormatException(this.reason);

  /// A description of what was wrong. Contains no token material.
  final String reason;

  @override
  String toString() => 'AoidClaimsFormatException: $reason';
}

/// Reads [name] from [payload] as a non-empty String, or throws.
///
/// Coercion is refused deliberately: turning a numeric `tnt` into `"42"` would
/// mint an [AoidActiveTenantSlug] that is not a slug.
String _requireString(Map<String, dynamic> payload, String name) {
  final v = payload[name];
  if (v is! String || v.isEmpty) {
    throw AoidClaimsFormatException(
      'claim `$name` is missing or not a non-empty string',
    );
  }
  return v;
}

String? _optionalString(Map<String, dynamic> payload, String name) {
  final v = payload[name];
  return v is String && v.isNotEmpty ? v : null;
}

/// Decodes [jwt] and returns its payload map, converting every failure mode
/// into an [AoidClaimsFormatException] whose message quotes nothing.
Map<String, dynamic> _payloadOf(String jwt, String tokenKind) {
  Object? payload;
  try {
    payload = JWT.decode(jwt).payload;
  } catch (_) {
    // Swallowing the cause is the point — see AoidClaimsFormatException.
    throw AoidClaimsFormatException('$tokenKind is not a decodable JWT');
  }
  if (payload is! Map<String, dynamic>) {
    throw AoidClaimsFormatException("$tokenKind payload is not a JSON object");
  }
  return payload;
}

/// The claims AOID puts on an OAuth **access token**, decoded but NOT verified.
///
/// UNVERIFIED DECODE. The client CANNOT verify an AOID signature — JWKS fetch,
/// algorithm pinning and clock-skew handling all belong on the server (see
/// `eden-biz/go/internal/aoidverify/direct_verifier.go`). These claims are for
/// **UI HINTING ONLY**; the server always re-verifies. Same doctrine as
/// `EdenFeatureGate`: never make this the enforcement point.
final class AoidAccessClaims {
  const AoidAccessClaims({
    required this.activeTenant,
    required this.subject,
    required this.entitlements,
    required this.aal,
    required this.clientId,
    required this.expiresAt,
  });

  /// `tnt` — the SLUG of the ACTIVE tenant. Follows tenant switching; equals the
  /// HOME tenant's slug when nothing is selected (GID-14).
  ///
  /// Typed so it cannot be confused with [AoidIdClaims.homeTenant], which is a
  /// UUID and does not follow switching.
  final AoidActiveTenantSlug activeTenant;

  /// `sub` — the GLOBAL `identities.id` (GID-13). Independent of the tenant
  /// axis; do not read it as tenant-scoped.
  final String subject;

  /// `ent` — AOID **identity/role** entitlements, mirroring the
  /// identity-context entitlement set for the ACTIVE tenant.
  ///
  /// This is NOT the eden-biz plan/billing axis served by
  /// `/api/v1/entitlements/bootstrap`. Same word, unrelated systems: AOID's
  /// `ent` answers "what is this identity allowed to be", eden-biz's answers
  /// "what has this account paid for". Do not conflate them, and do not gate a
  /// paid feature on this claim.
  ///
  /// Empty on machine (client_credentials) tokens.
  final List<String> entitlements;

  /// `aal` — authenticator assurance level, absent when AOID omits it.
  final String? aal;

  /// `client_id` — the OAuth client this token was minted for.
  final String clientId;

  /// `exp` as UTC. Note this is a HINT: nothing here validates it, and
  /// `JWT.decode` does not check expiry.
  final DateTime expiresAt;

  /// UNVERIFIED decode of an access token. See the class doc: UI HINTING ONLY,
  /// the server always re-verifies.
  ///
  /// Throws [AoidClaimsFormatException] — which carries no token material — if
  /// [jwt] is not a decodable access token.
  static AoidAccessClaims decodeUnverified(String jwt) {
    final payload = _payloadOf(jwt, 'access token');

    final exp = payload['exp'];
    if (exp is! int) {
      throw const AoidClaimsFormatException(
        'claim `exp` is missing or not an integer',
      );
    }

    final rawEnt = payload['ent'];
    final entitlements = rawEnt is List
        ? List<String>.unmodifiable(rawEnt.whereType<String>())
        : const <String>[];

    return AoidAccessClaims(
      activeTenant: AoidActiveTenantSlug(_requireString(payload, 'tnt')),
      subject: _requireString(payload, 'sub'),
      entitlements: entitlements,
      aal: _optionalString(payload, 'aal'),
      clientId: _requireString(payload, 'client_id'),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true),
    );
  }
}

/// The claims AOID puts on an OIDC **id_token**, decoded but NOT verified.
///
/// UNVERIFIED DECODE. The client CANNOT verify an AOID signature — JWKS fetch,
/// algorithm pinning and clock-skew handling all belong on the server (see
/// `eden-biz/go/internal/aoidverify/direct_verifier.go`). These claims are for
/// **UI HINTING ONLY**; the server always re-verifies. Same doctrine as
/// `EdenFeatureGate`: never make this the enforcement point.
final class AoidIdClaims {
  const AoidIdClaims({
    required this.homeTenant,
    required this.subject,
    required this.email,
    required this.emailVerified,
  });

  /// `tnt` — the UUID of the HOME tenant. Stable across active-tenant switches.
  ///
  /// Typed so it cannot be confused with [AoidAccessClaims.activeTenant], which
  /// is a slug and does follow switching. This is the value to key local user
  /// linking on.
  final AoidHomeTenantId homeTenant;

  /// `sub` — the GLOBAL `identities.id` (GID-13), identical to the access
  /// token's. Independent of the tenant axis.
  final String subject;

  /// `email`, absent when AOID omits it.
  final String? email;

  /// `email_verified`, false when the claim is absent.
  final bool emailVerified;

  /// UNVERIFIED decode of an id_token. See the class doc: UI HINTING ONLY, the
  /// server always re-verifies.
  ///
  /// Throws [AoidClaimsFormatException] — which carries no token material — if
  /// [jwt] is not a decodable id_token.
  static AoidIdClaims decodeUnverified(String jwt) {
    final payload = _payloadOf(jwt, 'id token');
    return AoidIdClaims(
      homeTenant: AoidHomeTenantId(_requireString(payload, 'tnt')),
      subject: _requireString(payload, 'sub'),
      email: _optionalString(payload, 'email'),
      emailVerified: payload['email_verified'] == true,
    );
  }
}
