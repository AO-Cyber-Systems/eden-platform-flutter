// AOID native-login errors — the client half of the issuer taxonomy.
//
// RIVERPOD-FREE and Flutter-free: reachable from lib/aoid.dart, whose
// transitive closure test/aoid/riverpod_free_gate_test.dart walks.

/// The wire error vocabulary of `/oauth/native/*`, per
/// draft-ietf-oauth-first-party-apps-03 and AOID.
///
/// These five are AUTHENTICATION-LAYER outcomes. `temporarily_unavailable`
/// (503) and `server_error` (500) are deliberately NOT here: they are
/// availability failures, not authentication decisions, and they surface as
/// [AoidTransportError] so a replica failover or a blip can never be rendered
/// as "login failed" or turned into a sign-out. See [AoidTransportError].
enum AoidErrorCode {
  /// The request shape was wrong. 400.
  invalidRequest,

  /// EVERY client-resolution failure — unknown client, native login not
  /// enabled for it, origin not on its allowlist. 400. The issuer makes all
  /// of them byte-identical so the endpoint cannot enumerate registrations.
  invalidClient,

  /// Handle-lifecycle failure. 400.
  invalidSession,

  /// A factor is still outstanding. 401.
  ///
  /// This is USUALLY NOT AN ERROR: the issuer's `Verify` answers
  /// `insufficient_authorization` with the ROTATED handle in the body on every
  /// intermediate step, and a failed factor answers it identically. Both are
  /// [AoidNativeContinue], not a throw. An `AoidError` with this code is
  /// raised only when the response carried NO successor handle — the ceremony
  /// really is over.
  insufficientAuthorization,

  /// Fall back to the hosted browser flow. 400.
  ///
  /// NEVER surfaces as an `AoidError`. It is a first-class RESULT
  /// (`AoidNativeRedirect` wrapping `RedirectRequired`), because a social IdP,
  /// a PIV card, or a restrictive tenancy tier reaching this on a
  /// CORRECT password is normal (the issuer gate 7). The code is in this enum
  /// because it is part of the wire vocabulary, not because it is a failure.
  redirectToWeb,
}

/// An AOID native-login refusal, deliberately LOSSY.
///
/// [AoidErrorCode.invalidSession] covers replay, expiry, an unknown handle,
/// a cross-tenant presentation, a cross-client presentation AND attempt-cap
/// exhaustion, indistinguishably. The issuer folds them together on purpose
/// so the endpoint cannot be used as an account-existence or
/// tenancy-membership oracle. **Do not widen this.** If you find yourself
/// adding a `reason`, a `cause`, or a second message per branch, you are
/// rebuilding the oracle that the issuer spent a whole contract removing.
///
/// Messages are built from a FIXED VOCABULARY held in this file. Request
/// input — passwords, TOTP codes, backup codes, emails, `auth_session`
/// handles, client ids — is NEVER interpolated into a message, a `toString()`,
/// or a log line. The server's own `error_description` is deliberately NOT
/// used either: reflecting a server string is how input reaches a message
/// once someone changes the server.
class AoidError implements Exception {
  const AoidError(this.code);

  final AoidErrorCode code;

  /// The wire spelling, for telemetry. Never UI copy.
  String get wireCode => switch (code) {
    AoidErrorCode.invalidRequest => 'invalid_request',
    AoidErrorCode.invalidClient => 'invalid_client',
    AoidErrorCode.invalidSession => 'invalid_session',
    AoidErrorCode.insufficientAuthorization => 'insufficient_authorization',
    AoidErrorCode.redirectToWeb => 'redirect_to_web',
  };

  /// FIXED VOCABULARY. One message per code, and one code per message — so two
  /// causes that share a code are indistinguishable here too.
  String get message => switch (code) {
    AoidErrorCode.invalidRequest => 'the request could not be processed',
    AoidErrorCode.invalidClient => 'this application cannot sign you in',
    AoidErrorCode.invalidSession => 'this sign-in session is no longer valid',
    AoidErrorCode.insufficientAuthorization => 'sign-in could not be completed',
    AoidErrorCode.redirectToWeb => 'this sign-in must continue in a browser',
  };

  @override
  String toString() => 'AoidError($wireCode): $message';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is AoidError && code == other.code);

  @override
  int get hashCode => code.hashCode;
}

/// Why a request never produced an authentication decision.
enum AoidTransportFailureKind {
  /// The socket died, DNS failed, TLS failed — nothing reached AOID.
  network,

  /// `503 temporarily_unavailable`. A replica refusing a write. The
  /// ceremony may still be perfectly alive; honour `Retry-After`.
  unavailable,

  /// `500 server_error`, or any status AOID's contract does not define.
  server,

  /// A response body that was not the JSON object the contract promises.
  malformed,
}

/// A TRANSPORT failure — explicitly NOT an authentication failure.
///
/// `AoidOidcAuthStrategy.restoreSession` swallows every non-200 as `null`,
/// which `AuthNotifier` turns into `unauthenticated`; a 500 or a network blip
/// therefore signs the user out. AODex fixed that class of bug
/// (`aodex-flutter#15`). This type exists so the same defect cannot be written
/// here: a caller that only catches [AoidError] will not accidentally treat an
/// outage as a rejected credential.
///
/// Carries no response body and no request input — only the shape of the
/// failure, and `Retry-After` when AOID supplied one.
class AoidTransportError implements Exception {
  const AoidTransportError(
    this.kind, {
    this.statusCode,
    this.retryAfterSeconds,
  });

  final AoidTransportFailureKind kind;

  /// The HTTP status, when there was one. `null` for a socket-level failure.
  final int? statusCode;

  /// Seconds AOID asked the client to wait, from `Retry-After` on a 503.
  final int? retryAfterSeconds;

  /// FIXED VOCABULARY, as [AoidError.message].
  String get message => switch (kind) {
    AoidTransportFailureKind.network => 'could not reach the sign-in service',
    AoidTransportFailureKind.unavailable =>
      'the sign-in service is temporarily unavailable',
    AoidTransportFailureKind.server => 'the sign-in service had a problem',
    AoidTransportFailureKind.malformed =>
      'the sign-in service sent an unexpected response',
  };

  @override
  String toString() => 'AoidTransportError(${kind.name}): $message';
}
