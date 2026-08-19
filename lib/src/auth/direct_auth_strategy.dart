// Copyright 2026 AOCyber. All rights reserved.
//
// DirectAuthStrategy — the application authenticates against its OWN backend
// and holds the resulting session (PLAT-02).
//
// This behaviour already existed, but only as the path [AuthNotifier] takes
// when NO strategy is injected. That made it unselectable: an app could not
// say "use direct" the way it can say "use the redirect flow", because direct
// was what you got by leaving something unconfigured. Expressing it as a
// strategy makes the mode a configuration choice, which is the whole point of
// the strategy seam.
//
// Injecting this is therefore behaviourally equivalent to injecting nothing —
// deliberately. The difference is that the intent is now written down.

import '../api/platform_repository.dart';
import '../models/platform_models.dart';
import 'auth_strategy.dart';
import 'token_storage.dart';

/// Single-step authentication against the application's own backend.
///
/// No issuer, no browser hop, no second factor: [completeLogin] always fails,
/// because there is no second step to complete.
class DirectAuthStrategy implements AuthStrategy {
  DirectAuthStrategy({required PlatformRepository repository, TokenStorage? tokenStorage})
    : _repository = repository,
      _tokenStorage = tokenStorage;

  final PlatformRepository _repository;

  /// Optional. When supplied, the session survives a restart: tokens are
  /// written on success and read back by [restoreSession]. Without it the
  /// strategy is memory-only and every launch starts logged out.
  final TokenStorage? _tokenStorage;

  @override
  Future<AuthResult> initiateLogin(Map<String, String> credentials) async {
    final email = credentials['email'];
    final password = credentials['password'];
    if (email == null || email.isEmpty || password == null || password.isEmpty) {
      // Refused locally, on purpose. Sending a half-filled form spends an
      // authentication attempt against a backend that rate-limits them, and
      // the user gets a lockout instead of "fill in the password".
      return const Failed('Enter both an email address and a password.');
    }
    try {
      final session = await _repository.login(email, password);
      await _persist(session);
      return Authenticated(session);
    } catch (e) {
      // Never propagate. AuthNotifier drives its state machine off AuthResult,
      // so a strategy that throws bypasses the machine entirely and the UI is
      // left in whatever state it was mid-submit.
      return Failed(_describe(e));
    }
  }

  /// Always [Failed]: direct login is single-step by construction. Returning
  /// anything else would imply a continuation the backend cannot honour.
  @override
  Future<AuthResult> completeLogin(
    String continuationToken,
    Map<String, String> proof,
  ) async => const Failed('Direct login completes in one step.');

  @override
  Future<void> logout() async {
    final storage = _tokenStorage;
    try {
      final refresh = storage == null ? null : await storage.readRefreshToken();
      if (refresh != null && refresh.isNotEmpty) {
        await _repository.logout(refresh);
      }
    } catch (_) {
      // Best-effort by contract. A failed server-side revoke must not trap a
      // user in a session they have asked to leave, so the local clear below
      // happens either way.
    }
    if (storage != null) {
      await storage.clear();
    }
  }

  /// Always null: a direct session cannot be rebuilt from stored tokens.
  ///
  /// [PlatformSession] requires a `user`, and the tokens are all this strategy
  /// persists — the backend's notion of who the caller is lives behind its own
  /// `/me`-style endpoint, which this package does not know the shape of.
  /// Fabricating a placeholder user here would hand downstream widgets an
  /// identity the server never asserted.
  ///
  /// Apps that want restore should either implement it against their own
  /// endpoint or wrap this strategy. Returning null re-prompts, which is the
  /// recoverable failure.
  @override
  Future<PlatformSession?> restoreSession() async => null;

  Future<void> _persist(PlatformSession session) async {
    final storage = _tokenStorage;
    if (storage == null || session.cookieBound) return;
    await storage.writeAccessToken(session.accessToken);
    await storage.writeRefreshToken(session.refreshToken);
  }

  static String _describe(Object e) {
    final s = e.toString();
    return s.startsWith('Exception: ') ? s.substring(11) : s;
  }
}
