// Copyright 2026 AOCyber. All rights reserved.
//
// NativeCeremony — the multi-step, no-redirect login ceremony, as the strategy
// layer needs to see it (PLAT-02).
//
// [AoidNativeFlow] already implements exactly this shape. The interface exists
// so [NativeDelegatedAuthStrategy] depends on the CEREMONY, not on one
// concrete client: a consumer with its own first-party issuer can satisfy this
// and get the same strategy, which is the point of PLAT-02's "selecting a mode
// is configuration, not a fork".
//
// It is deliberately NARROW. Notably it exposes no `auth_session` handle:
// the flow consumes and rotates that on every step, so anything holding a copy
// holds a dead value. Continuation is the strategy's problem, not the caller's.

import '../aoid/flow/aoid_native_flow.dart';

/// A multi-step credential ceremony that completes without a browser hop.
abstract interface class NativeCeremony {
  /// Where the ceremony stands. The strategy maps this onto `AuthResult`.
  AoidFlowState get state;

  /// Mint a ceremony. [codeChallenge] binds it to a PKCE verifier the caller
  /// keeps, so the terminal code is redeemable only by whoever started this.
  Future<void> begin({required String codeChallenge, String? loginHint});

  /// Submit the knowledge factor.
  Future<void> submitPassword({required String email, required String password});

  /// Submit a TOTP or backup code.
  Future<void> submitOtp(String otp);

  /// Submit a WebAuthn assertion, verbatim — re-encoding invalidates the
  /// signature, which covers those exact bytes.
  Future<void> submitWebAuthn(String responseJson, {String method});
}
