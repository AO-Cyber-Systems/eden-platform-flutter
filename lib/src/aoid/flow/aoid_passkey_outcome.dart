// The closed result of one passkey sign-in attempt (Objective 52, TRD 52-03).
//
// EXPORTED through lib/src/aoid/parts/native.dart, unlike everything in
// lib/src/aoid/passkey/: the sealed AoidLoginForm (52-04) renders from it, and
// it carries no credential material — only WHAT happened, in a closed
// vocabulary.
//
// Plain Dart: no imports, so the flow stays Flutter-free.

/// What happened to one passkey sign-in attempt
/// (`AoidNativeFlow.signInWithPasskey`).
///
/// CLOSED, and NOT UI copy: the sealed form owns the wording. No value says
/// WHY in the operating system's terms, and [rejected] is deliberately as
/// opaque as a wrong password — AOID gives no reason, and inventing one would
/// rebuild the account-existence oracle the issuer removed.
///
/// Every value except [completed] and [interrupted] means the flow has
/// already started a FRESH ceremony on its own (AOID has no edge from
/// `webauthn_pending` back to `password`), so the form is usable again
/// without the app doing anything.
enum AoidPasskeyOutcome {
  /// Signed in. `AoidNativeFlow.state` is `AoidFlowComplete`.
  completed,

  /// AOID refused the assertion. The refusal is opaque on purpose. A fresh
  /// ceremony was started.
  rejected,

  /// The user dismissed the system sheet — or had no passkey for this relying
  /// party; Apple reports both the same way and does not say which. A fresh
  /// ceremony was started. Calm: say nothing.
  cancelled,

  /// No passkey sign-in is possible here: the start reply did not offer one,
  /// the app is not associated with the relying party's domain, or the
  /// platform has no passkey API. When a ceremony had been entered, a fresh one
  /// was started.
  unavailable,

  /// Any other authenticator failure, or a challenge AOID sent malformed. A
  /// fresh ceremony was started.
  failed,

  /// The ceremony stopped for a reason `AoidNativeFlow.state` already
  /// describes — a network failure, a 503, an ended session
  /// (`invalid_session`), a redirect to the web, `invalid_client` — or a fresh
  /// ceremony could not be started. Render from `state`, as for every other
  /// step. NOT restarted: after a 503 the handle is still valid and the user
  /// may simply try again.
  interrupted,
}
