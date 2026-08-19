// Copyright 2026 AOCyber. All rights reserved.
//
// AuthStrategy — pluggable authentication flow for consumers whose
// login surface differs from the canonical email+password Eden flow.
//
// The default [AuthNotifier] (see auth_provider.dart) supports a one-shot
// `login(email, password)` flow against the Eden PlatformRepository. Some
// consumers need a multi-step flow (e.g., AOID's
// PasswordLoginStart → MFA → PasswordLoginComplete) or a cookie-bound
// session that doesn't carry an access/refresh token pair at all. Rather
// than fork [AuthNotifier], consumers implement [AuthStrategy] and inject
// it via `AuthNotifier(strategy: …)`; the notifier delegates lifecycle
// operations to the strategy while keeping the [AuthState] surface
// identical for downstream widgets.
//
// Backward compatibility: passing no strategy preserves the legacy
// email+password behavior — the notifier continues to call
// `repository.login(email, password)` directly.

import '../models/platform_models.dart';

/// Result of an [AuthStrategy.initiateLogin] / [AuthStrategy.completeLogin]
/// step. Modeled as a sealed family so callers can exhaustively switch
/// without invariant guards.
sealed class AuthResult {
  const AuthResult();
}

/// The strategy has produced a valid [PlatformSession]; the notifier should
/// transition to [AuthStatus.authenticated].
class Authenticated extends AuthResult {
  final PlatformSession session;
  const Authenticated(this.session);
}

/// The server needs another factor before authentication can complete.
///
/// [continuationToken] is the CURRENT handle and MAY DIFFER from the one the
/// caller presented — AOID rotates `auth_session` on every step
/// as its session-fixation defence.
///
/// **Callers MUST replace their stored handle with this value.**
///
/// Re-presenting the previous one yields `invalid_session` and will look like
/// a server bug.
///
/// [availableMethods] may be EMPTY: the issuer deliberately does not emit
/// `available_methods` before a factor has succeeded, because doing so would
/// make the endpoint an enumeration oracle. Render a picker only when
/// it is non-empty.
class FactorRequired extends AuthResult {
  /// The rotated `auth_session` handle to present on the next step.
  final String continuationToken;

  /// Which factor the server wants next — `'password'`, `'mfa'`, … Mirrors
  /// the wire field `next`.
  final String next;

  /// Factors the identity can actually satisfy for [next] — `'totp'`,
  /// `'backup_code'`, `'webauthn'`, … Mirrors the wire field
  /// `available_methods`. Empty until a factor has succeeded.
  final List<String> availableMethods;

  const FactorRequired({
    required this.continuationToken,
    required this.next,
    this.availableMethods = const [],
  });
}

/// The strategy needs a second factor before authentication can complete.
/// The notifier transitions to [AuthStatus.refreshing] and surfaces
/// [continuationToken] so the UI can submit the second step via
/// [AuthStrategy.completeLogin]. The continuation token may be opaque (a
/// server-side session cookie reference, an MFA challenge id, etc.).
///
/// DEPRECATED. Retained as a SUBCLASS of [FactorRequired] so existing
/// implementations keep compiling unchanged — notably AOID's portal, which
/// constructs this `const` at
/// the portal's own strategy implementation. Because it is a
/// subclass, a `case FactorRequired(...)` arm already matches it; no consumer
/// has to change. Prefer [FactorRequired], which carries the rotated handle
/// and the method list.
@Deprecated('Use FactorRequired — carries the rotated handle + method list')
class TwoFactorRequired extends FactorRequired {
  const TwoFactorRequired(String token)
    : super(continuationToken: token, next: 'mfa', availableMethods: const []);
}

/// This factor cannot be completed in-app: a social IdP, PIV/CAC, or a tenant
/// whose isolation tier forbids native login (a restrictive isolation tier —
/// `cryptographic` or `physical`). The caller opens [authorizationUrl] in
/// a system browser and completes via the redirect flow.
///
/// This is NOT an error. Do not render it as one, and do
/// not map it onto [AuthStatus.error].
///
/// Wire origin: AOID answers `400 {"error":"redirect_to_web",
/// "error_description":"…","authorization_url":"…"}`. The wire code is
/// spelled `redirect_to_web`, per draft-ietf-oauth-first-party-apps-03 and
/// the spec, and that is the ONLY spelling — the design notes' informal prose
/// name for this case is not a wire value and must never appear in code.
class RedirectRequired extends AuthResult {
  /// Where to send the system browser. Built by AOID from the ceremony's own
  /// binding, so it carries no credential (the spec asserts the query key set
  /// structurally).
  final Uri authorizationUrl;

  /// TELEMETRY ONLY. Never branch UI on this and never show it to a user.
  /// the issuer error mapper is deliberately lossy so the client cannot
  /// become an account-existence or tenancy-tier oracle.
  final String? reason;

  const RedirectRequired(this.authorizationUrl, {this.reason});
}

/// The strategy could not authenticate the caller. The notifier transitions
/// to [AuthStatus.error] with [reason] as the user-facing message.
///
/// Reserve this for TERMINAL failures. [AuthNotifier] clears its continuation
/// token here, so a RECOVERABLE factor error (a wrong TOTP code the user may
/// retry) returned as [Failed] makes the ceremony unrecoverable — return
/// [FactorRequired] with the rotated handle instead. The strategy implementation
/// owns that mapping.
class Failed extends AuthResult {
  final String reason;
  const Failed(this.reason);
}

/// Contract for a custom authentication flow injected into [AuthNotifier].
///
/// Implementations are free to call any RPC, persist any state, and
/// produce any [PlatformSession] shape (including
/// [PlatformSession.cookieBound] for cookie-only flows). The notifier only
/// observes [AuthResult] transitions to drive its [AuthState] machine.
abstract class AuthStrategy {
  /// Start the login flow. For single-step flows return [Authenticated] or
  /// [Failed]. For multi-step flows return [FactorRequired] with the handle
  /// the UI passes back via [completeLogin].
  ///
  /// A strategy may also return [RedirectRequired] when the factor cannot be
  /// completed in-app (social IdP, PIV/CAC, or a tenancy tier that forbids
  /// native login). That is a normal outcome, NOT a failure — see
  /// [RedirectRequired].
  ///
  /// [credentials] is an opaque map (e.g. `{'email':..., 'password':...}`)
  /// so strategies aren't constrained to email+password.
  Future<AuthResult> initiateLogin(Map<String, String> credentials);

  /// Complete a multi-step login. [continuationToken] is the value returned
  /// by the previous step in [FactorRequired.continuationToken] — always the
  /// most recent one, because AOID rotates it on every step. [proof]
  /// carries the factor (e.g. `{'totp': '123456'}` or
  /// `{'webauthn_assertion':...}`).
  ///
  /// May return [FactorRequired] again for an N-th factor, [RedirectRequired]
  /// if the remaining factor needs a browser hop, [Authenticated], or [Failed].
  /// Single-step strategies may return [Failed] from this method.
  Future<AuthResult> completeLogin(
    String continuationToken,
    Map<String, String> proof,
  );

  /// Tear down the session. Implementations should clear any persisted
  /// cookies / tokens and call the server-side revoke endpoint if one
  /// exists. Best-effort — must not throw on server-side errors.
  Future<void> logout();

  /// Probe whether a session can be restored at app boot. Returns the
  /// restored [PlatformSession] on success or `null` if no session is
  /// available. Implementations should NOT throw on transient network
  /// errors; they should return null and let the UI re-prompt for login.
  Future<PlatformSession?> restoreSession();
}
