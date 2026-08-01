// R-ACL-04 AoidConfig — env-driven config for wiring AoidOidcAuthStrategy
// into a consumer app.
//
// RIVERPOD-FREE BY CONSTRUCTION. This file is reachable from
// `package:eden_platform_flutter/aoid.dart`, which a flutter_riverpod 3.x
// consumer must be able to import (see lib/aoid.dart). The provider wiring
// that used to live here — aoidConfigProvider, buildAoidStrategy,
// buildAoidOverrides — now lives in
// lib/src/aoid_riverpod/aoid_config_riverpod.dart and is re-exported from
// lib/aoid_riverpod.dart. Both remain reachable from lib/eden_platform.dart,
// so existing consumers are unaffected.
// Enforced by test/aoid/riverpod_free_gate_test.dart — do not add an import
// here that reaches riverpod.
//
// `bool.fromEnvironment`/`String.fromEnvironment` are COMPILE-TIME constants
// — a widget/provider test cannot set them per test case. This value class
// takes explicit constructor args so it's fully unit-testable; only the
// [AoidConfig.fromEnvironment] factory (the PRODUCTION path) touches the
// `--dart-define` constants. Tests override `aoidConfigProvider` instead of
// relying on the factory.
//
// Fail-fast: when [enabled] is true, [issuer]/[clientId] MUST be non-empty.
// [validate] throws a [StateError] rather than silently wiring a strategy
// with empty issuer/clientId.
// Flag OFF (enabled=false) is a no-op regardless of issuer/clientId content
// — zero behavior change to password login is a hard requirement.
//
// Promoted from eden-biz-console-login/flutter (AOID-CONSOLE-LOGIN-04-TRD)
// into this shared package.

/// Env-driven AOID OIDC login configuration for a consumer app.
class AoidConfig {
  const AoidConfig({
    required this.enabled,
    required this.issuer,
    required this.clientId,
  });

  /// Reads the AOID_CONSOLE_LOGIN_ENABLED / AOID_ISSUER / AOID_CLIENT_ID
  /// `--dart-define` compile-time constants. This is the PRODUCTION path;
  /// tests should override `aoidConfigProvider` instead of calling this.
  factory AoidConfig.fromEnvironment() => const AoidConfig(
        // AOID login is the DEFAULT: on unless a build explicitly passes
        // --dart-define=AOID_CONSOLE_LOGIN_ENABLED=false. issuer/clientId
        // default to the prod eden-biz web console so the fail-fast guard is
        // satisfied without dart-defines; other RPs (mobile/pos) override
        // AOID_CLIENT_ID (and any env its issuer differs).
        //
        // NOTE (AOID obj-50): these defaults are a live production concern —
        // 50-CONTEXT C3 flags the default-on web path as durably storing a
        // refresh token. TRD 50-02 owns that fix. This TRD relocated the file
        // WITHOUT changing behaviour, deliberately, so the security change
        // lands as its own reviewable diff.
        enabled: bool.fromEnvironment('AOID_CONSOLE_LOGIN_ENABLED',
            defaultValue: true),
        issuer: String.fromEnvironment('AOID_ISSUER',
            defaultValue: 'https://auth.aocyber.ai'),
        clientId: String.fromEnvironment('AOID_CLIENT_ID',
            defaultValue: 'eden-biz-console'),
      );

  /// Whether the AOID OIDC login strategy should be wired in place of the
  /// legacy email+password flow.
  final bool enabled;

  /// AOID issuer origin, e.g. `https://auth.aocyber.ai`.
  final String issuer;

  /// Public OAuth client id, e.g. `eden-biz-console`.
  final String clientId;

  /// The registered redirect_uri for [webOrigin], e.g.
  /// `https://console.biz.aocyber.ai` -> `.../auth.html`.
  String redirectUri(String webOrigin) => '$webOrigin/auth.html';

  /// Fail-fast guard: when [enabled] is true, [issuer] and [clientId] MUST
  /// be non-empty. Throws [StateError] otherwise. No-op when [enabled] is
  /// false — flag-off must be zero behavior change regardless of what
  /// issuer/clientId happen to contain.
  void validate() {
    if (!enabled) return;
    if (issuer.isEmpty) {
      throw StateError(
        'AoidConfig: AOID_CONSOLE_LOGIN_ENABLED=true requires a non-empty '
        'AOID_ISSUER',
      );
    }
    if (clientId.isEmpty) {
      throw StateError(
        'AoidConfig: AOID_CONSOLE_LOGIN_ENABLED=true requires a non-empty '
        'AOID_CLIENT_ID',
      );
    }
  }
}
