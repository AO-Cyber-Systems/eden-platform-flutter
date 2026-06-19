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

/// The strategy needs a second factor before authentication can complete.
/// The notifier transitions to [AuthStatus.refreshing] and surfaces
/// [continuationToken] so the UI can submit the second step via
/// [AuthStrategy.completeLogin]. The continuation token may be opaque (a
/// server-side session cookie reference, an MFA challenge id, etc.).
class TwoFactorRequired extends AuthResult {
  final String continuationToken;
  const TwoFactorRequired(this.continuationToken);
}

/// The strategy could not authenticate the caller. The notifier transitions
/// to [AuthStatus.error] with [reason] as the user-facing message.
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
  /// [Failed]. For multi-step flows return [TwoFactorRequired] with a
  /// continuation token the UI can pass back via [completeLogin].
  ///
  /// [credentials] is an opaque map (e.g. `{'email': ..., 'password': ...}`)
  /// so strategies aren't constrained to email+password.
  Future<AuthResult> initiateLogin(Map<String, String> credentials);

  /// Complete a multi-step login. [continuationToken] is the value returned
  /// by [initiateLogin] in [TwoFactorRequired]. [proof] carries the second
  /// factor (e.g. `{'totp': '123456'}` or `{'webauthn_assertion': ...}`).
  ///
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
