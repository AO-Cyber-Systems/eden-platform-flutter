// Where the SDK's own widgets obtain their passkey authenticator (Objective
// 52, TRD 52-01). The sealed login form (TRD 52-04) calls
// [resolveAoidPasskeyAuthenticator]; it gains no constructor parameter.
//
// NOT EXPORTED. Neither this resolver nor the authenticator it returns is
// reachable from package:eden_platform_flutter/eden_platform.dart or any
// part-barrel (pinned by test/aoid/passkey/aoid_passkey_resolver_test.dart).
// A consuming app therefore has no way to substitute an authenticator and so
// observe a real OS assertion (52-CONTEXT locked decision 1).

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'aoid_passkey_authenticator.dart';
import 'aoid_platform_passkey_authenticator.dart';

AoidPasskeyAuthenticator? _debugOverride;

/// TEST SEAM. Assignable only while asserts are enabled: in a release build
/// the assert body is compiled out, so the assignment never happens and no
/// consuming app can substitute an authenticator, and thereby observe a real
/// OS assertion (locked decision 1). Tests reset it to `null` in `tearDown`.
@visibleForTesting
set debugAoidPasskeyAuthenticatorOverride(AoidPasskeyAuthenticator? value) {
  assert(() {
    _debugOverride = value;
    return true;
  }());
}

/// The authenticator the SDK's widgets use: the in-package iOS/macOS platform
/// channel, unless a test installed an override under asserts.
AoidPasskeyAuthenticator resolveAoidPasskeyAuthenticator() =>
    _debugOverride ?? const AoidPlatformPasskeyAuthenticator();
