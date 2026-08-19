// Copyright 2026 AOCyber. All rights reserved.
//
// NativeDelegatedAuthStrategy — delegated authentication WITHOUT a browser hop
// (PLAT-02).
//
// The application renders its own login form and exchanges credentials with a
// first-party issuer directly. The ceremony itself already existed as
// [AoidNativeFlow]; what did not exist was any way to SELECT it through
// [AuthStrategy], so an app wanting this mode had to drive the flow by hand and
// reimplement the state mapping — the fork PLAT-02 exists to remove.
//
// WHY THE CONTINUATION TOKEN IS NOT THE CEREMONY HANDLE
//
// The ceremony consumes and rotates its `auth_session` on every step: the
// handle presented is dead the moment it leaves, and only the response installs
// a successor. It is therefore private with no accessor, deliberately.
//
// [FactorRequired.continuationToken] is a value the UI holds across a user
// interaction and hands back. Those two are incompatible, so this strategy
// issues an OPAQUE token of its own and keeps the ceremony. The token
// identifies "the ceremony this strategy is running"; the live handle stays
// where it can be rotated safely.

import 'dart:math';

import '../aoid/flow/aoid_native_flow.dart';
import '../aoid/mode/aoid_code_sink.dart';
import '../aoid/mode/aoid_deployment_mode.dart' show AoidSessionPlatformBridge;
import '../aoid/pkce.dart';
import '../models/platform_models.dart';
import 'auth_strategy.dart';
import 'native_ceremony.dart';

/// The identity a native session carries before the app resolves its own.
///
/// The ceremony authenticates; it does not describe the user. Mirrors the
/// redirect strategy's placeholder rather than inventing a second convention.
const PlatformUser _placeholderUser = PlatformUser(
  id: '',
  email: '',
  displayName: '',
  isActive: true,
);

/// Multi-step credential authentication against a first-party issuer, with no
/// browser hop unless a factor demands one.
class NativeDelegatedAuthStrategy implements AuthStrategy {
  NativeDelegatedAuthStrategy({
    required NativeCeremony flow,
    required AoidCodeSink codeSink,
    String? redirectUri,
    PkcePair Function()? pkceFactory,
    Random? random,
  }) : _flow = flow,
       _sink = codeSink,
       _redirectUri = redirectUri,
       _pkceFactory = pkceFactory ?? PkceGenerator.generate,
       _random = random ?? Random.secure();

  final NativeCeremony _flow;
  final AoidCodeSink _sink;
  final String? _redirectUri;
  final PkcePair Function() _pkceFactory;
  final Random _random;

  /// The PKCE verifier for the ceremony in flight. Held for exactly as long as
  /// the ceremony: it is what proves the terminal code belongs to this client.
  String? _verifier;

  /// The opaque handle this strategy hands the UI. See the header.
  String? _continuation;

  @override
  Future<AuthResult> initiateLogin(Map<String, String> credentials) async {
    final email = credentials['email'];
    final password = credentials['password'];
    if (email == null || email.isEmpty || password == null || password.isEmpty) {
      // Refused before `begin`. Starting a ceremony burns a durable attempt
      // against the issuer's per-handle cap, so a half-filled form would cost
      // the user one of a small number of tries.
      return const Failed('Enter both an email address and a password.');
    }

    final pkce = _pkceFactory();
    _verifier = pkce.codeVerifier;
    _continuation = null;

    try {
      await _flow.begin(codeChallenge: pkce.codeChallenge, loginHint: email);
      // A ceremony that could not start has nothing to submit into.
      final started = _flow.state;
      if (started is! AoidFlowAwaitingFactor) return await _map(started);

      await _flow.submitPassword(email: email, password: password);
      return await _map(_flow.state);
    } catch (e) {
      return Failed(_describe(e));
    }
  }

  @override
  Future<AuthResult> completeLogin(
    String continuationToken,
    Map<String, String> proof,
  ) async {
    final expected = _continuation;
    if (expected == null || continuationToken != expected) {
      // Not merely tidiness: submitting into someone else's ceremony, or into
      // one already torn down, spends an attempt the user did not authorise.
      return const Failed('That sign-in attempt is no longer valid. Start again.');
    }

    final otp = proof['totp'] ?? proof['otp'] ?? proof['backup_code'];
    final assertion = proof['webauthn_assertion'] ?? proof['webauthn_response'];
    try {
      if (otp != null && otp.isNotEmpty) {
        await _flow.submitOtp(otp);
      } else if (assertion != null && assertion.isNotEmpty) {
        await _flow.submitWebAuthn(assertion);
      } else {
        return const Failed('No verification code was supplied.');
      }
      return await _map(_flow.state);
    } catch (e) {
      return Failed(_describe(e));
    }
  }

  @override
  Future<void> logout() async {
    // Nothing to revoke here. The ceremony is not a session — whatever the code
    // sink established owns the session, and tearing that down is the app's
    // job because only it knows where the cookie or token went.
    _verifier = null;
    _continuation = null;
  }

  /// Always null. A ceremony is a login attempt, not a durable session; there
  /// is nothing of it to restore. Session restore belongs to whatever the code
  /// sink established.
  @override
  Future<PlatformSession?> restoreSession() async => null;

  /// Maps ceremony state onto the strategy contract.
  ///
  /// Every branch is deliberate; in particular a redirect is an OUTCOME, and a
  /// dead ceremony asks for a restart rather than reporting a bad credential.
  Future<AuthResult> _map(AoidFlowState s) async {
    switch (s) {
      case AoidFlowAwaitingFactor(:final next, :final availableMethods):
        _continuation = _mintContinuation();
        return FactorRequired(
          continuationToken: _continuation!,
          next: next,
          availableMethods: availableMethods,
        );

      case AoidFlowRedirectRequired(:final result):
        // Pass the ceremony's own value through. A factor that cannot complete
        // in-app is normal; mapping it onto Failed would tell a user with
        // perfectly good credentials that login failed.
        _continuation = null;
        return result;

      case AoidFlowComplete(:final authorizationCode):
        return _exchange(authorizationCode);

      case AoidFlowRestartRequired():
        _continuation = null;
        return const Failed('That sign-in attempt expired. Please try again.');

      case AoidFlowUnavailable(:final retryAfterSeconds):
        _continuation = null;
        return Failed(
          retryAfterSeconds == null
              ? 'Sign-in is temporarily unavailable. Please try again.'
              : 'Sign-in is temporarily unavailable. Try again in '
                  '$retryAfterSeconds seconds.',
        );

      case AoidFlowFailed():
        // The issuer's error mapping is deliberately lossy so the client cannot
        // become an account-existence oracle. Do not enrich it here — a richer
        // message would reconstruct exactly what the issuer withheld.
        _continuation = null;
        return const Failed('Sign-in failed. Check your details and try again.');

      case AoidFlowIdle():
        // Defensive: a ceremony that reports Idle after a submit is a client
        // bug, and admitting it would strand the UI with no next step.
        _continuation = null;
        return const Failed('Sign-in could not be started. Please try again.');
    }
  }

  Future<AuthResult> _exchange(String code) async {
    final verifier = _verifier;
    _continuation = null;
    if (verifier == null) {
      // Without the verifier the code cannot be proven to belong to this
      // client, and redeeming it anyway is the interception this binding exists
      // to prevent.
      return const Failed('Sign-in could not be completed. Please try again.');
    }
    try {
      final session = await _sink.submit(
        code: code,
        codeVerifier: verifier,
        redirectUri: _redirectUri,
      );
      return Authenticated(session.toPlatformSession(user: _placeholderUser));
    } catch (e) {
      return Failed(_describe(e));
    } finally {
      _verifier = null;
    }
  }

  /// An opaque, single-ceremony handle. Not derived from the `auth_session`,
  /// which is private and rotates — see the header.
  String _mintContinuation() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _describe(Object e) {
    final s = e.toString();
    return s.startsWith('Exception: ') ? s.substring(11) : s;
  }
}
