// The platform passkey authenticator, as the AOID flow sees it (Objective 52,
// TRD 52-01).
//
// FLUTTER-FREE ON PURPOSE. This file imports nothing: the native flow
// (lib/src/aoid/flow/) depends on it, and the flow is plain Dart. The Flutter
// implementation lives next door in aoid_platform_passkey_authenticator.dart.
//
// NOT EXPORTED. Nothing in lib/src/aoid/passkey/ is reachable from
// package:eden_platform_flutter/eden_platform.dart or any part-barrel
// (test/aoid/passkey/aoid_passkey_resolver_test.dart pins that). The assertion
// is produced and consumed inside the SDK: authenticator -> flow -> request
// body. App-owned Dart never holds it (52-CONTEXT locked decision 1).

/// Why a passkey assertion was not produced.
///
/// CLOSED: four values, no OS text, no detail. Every native error code maps
/// onto one of these and nothing else survives the boundary — an OS error
/// string is not UI copy, and the "not associated" one names the app's domain
/// configuration.
enum AoidPasskeyFailure {
  /// The user dismissed the system sheet, OR had no passkey for this relying
  /// party. Apple's modal flow reports both as `.canceled` and does not let us
  /// tell them apart (52-RESEARCH §4); both readings are non-enumerating, so
  /// the form treats them the same way: stay put, say nothing.
  cancelled,

  /// The app is not associated with the relying party's domain (no
  /// `webcredentials:` entitlement, or no AASA on the RP host). A consumer
  /// configuration problem, not a user problem.
  notAssociated,

  /// This platform has no platform passkey assertion API (web, Android,
  /// desktop other than macOS, an OS below iOS 16 / macOS 13), or the native
  /// half of the channel is not linked into the app.
  unsupported,

  /// Anything else. Deliberately uninformative.
  failed,
}

/// The result of one passkey assertion attempt. Sealed: exactly two outcomes.
sealed class AoidPasskeyAttempt {
  const AoidPasskeyAttempt();
}

/// The assertion, as the WebAuthn JSON AOID verifies.
///
/// Opaque on purpose: pass [responseJson] to the AOID native flow and nowhere
/// else. Never log it — [toString] is redacted so an accidental interpolation
/// cannot.
final class AoidPasskeyAsserted extends AoidPasskeyAttempt {
  const AoidPasskeyAsserted(this.responseJson);

  /// The assembled WebAuthn assertion JSON. The base64url fields inside it are
  /// the OS's bytes, untouched: the signature covers
  /// `authenticatorData || SHA-256(clientDataJSON)`, so any re-encoding breaks
  /// verification.
  final String responseJson;

  @override
  String toString() => 'AoidPasskeyAsserted(<redacted>)';
}

/// No assertion was produced, for a [reason] from the closed vocabulary.
final class AoidPasskeyNotAsserted extends AoidPasskeyAttempt {
  const AoidPasskeyNotAsserted(this.reason);

  final AoidPasskeyFailure reason;

  @override
  String toString() => 'AoidPasskeyNotAsserted(${reason.name})';
}

/// Produces a platform-authenticator assertion for a discoverable WebAuthn
/// challenge.
abstract interface class AoidPasskeyAuthenticator {
  /// Whether the OS offers the platform passkey ASSERTION API here.
  ///
  /// This does NOT mean "the user has a passkey" — nothing can answer that
  /// without showing the system sheet. It means a passkey button can work.
  /// Never throws: an unreachable native half answers `false`.
  Future<bool> isSupported();

  /// Asks the platform authenticator for an assertion.
  ///
  /// [publicKey] is the server's `webauthn_challenge.publicKey` map, verbatim.
  /// Never throws for an outcome a user or a consumer configuration can cause.
  Future<AoidPasskeyAttempt> getAssertion(Map<String, dynamic> publicKey);
}
