// R-ACL-04 AoidConfig — env-driven config for wiring AoidOidcAuthStrategy
// into a consumer app via authStrategyProvider.
//
// `bool.fromEnvironment`/`String.fromEnvironment` are COMPILE-TIME constants
// — a widget/provider test cannot set them per test case. This value class
// takes explicit constructor args so it's fully unit-testable; only the
// [AoidConfig.fromEnvironment] factory (the PRODUCTION path) touches the
// `--dart-define` constants. Tests override [aoidConfigProvider] instead of
// relying on the factory.
//
// Fail-fast: when [enabled] is true, [issuer]/[clientId] MUST be non-empty.
// [validate] throws a [StateError] rather than silently wiring a strategy
// with empty issuer/clientId.
// Flag OFF (enabled=false) is a no-op regardless of issuer/clientId content
// — zero behavior change to password login is a hard requirement.
//
// Promoted from eden-biz-console-login/flutter (AOID-CONSOLE-LOGIN-04-TRD)
// into this shared package, along with [buildAoidOverrides] (formerly a
// thin adapter in the console's main.dart — now that authStrategyProvider
// lives in the SAME package as this file, the narrow-src-import workaround
// that used to separate the two is no longer needed).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'aoid_oidc_auth_strategy.dart';
import 'auth_provider.dart';
import 'token_storage.dart';

/// Env-driven AOID OIDC login configuration for a consumer app.
class AoidConfig {
  const AoidConfig({
    required this.enabled,
    required this.issuer,
    required this.clientId,
  });

  /// Reads the AOID_CONSOLE_LOGIN_ENABLED / AOID_ISSUER / AOID_CLIENT_ID
  /// `--dart-define` compile-time constants. This is the PRODUCTION path;
  /// tests should override [aoidConfigProvider] instead of calling this.
  factory AoidConfig.fromEnvironment() => const AoidConfig(
        enabled: bool.fromEnvironment('AOID_CONSOLE_LOGIN_ENABLED'),
        issuer: String.fromEnvironment('AOID_ISSUER'),
        clientId: String.fromEnvironment('AOID_CLIENT_ID'),
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

/// Overridable Riverpod provider for [AoidConfig]. Production value reads
/// the compile-time env constants; tests override this provider directly.
final aoidConfigProvider = Provider<AoidConfig>((ref) {
  final cfg = AoidConfig.fromEnvironment();
  cfg.validate();
  return cfg;
});

/// Resolves the web origin used to derive the AOID redirect_uri. On web this
/// is the current page origin (e.g. `https://console.biz.aocyber.ai`); off
/// web `Uri.base` still yields a usable origin. Guarded so a malformed
/// `Uri.base` never crashes boot.
String _resolveWebOrigin() {
  try {
    return Uri.base.origin;
  } catch (_) {
    // Uri.base.origin throws for non-http(s) schemes (e.g. some desktop
    // sandboxes). AOID login is a web flow; fall back to an empty origin so
    // redirectUri is still well-formed ('/auth.html') and the fail-fast
    // validate() surface (empty issuer/clientId) still governs.
    return '';
  }
}

/// Pure, testable wiring core: builds the [AoidOidcAuthStrategy] a consumer
/// app should delegate to, or `null` when the flag is off.
///
/// - flag OFF ([AoidConfig.enabled]==false) -> returns `null`. Callers add
///   NO authStrategyProvider override, so AuthNotifier keeps the package
///   default (null strategy) and password login is unchanged.
/// - flag ON -> validates fail-fast (empty issuer/clientId throws), then
///   returns a strategy carrying the configured issuer/clientId and the
///   redirect_uri derived from [webOrigin] (defaults to the current web
///   origin via `Uri.base.origin`).
///
/// [storage] MUST be the SAME [TokenStorage] instance the caller overrides
/// `tokenStorageProvider` with, so the AOID refresh/rotate path and the rest
/// of the app read/write one token store.
AoidOidcAuthStrategy? buildAoidStrategy(
  AoidConfig cfg,
  TokenStorage storage, {
  String? webOrigin,
}) {
  cfg.validate();
  if (!cfg.enabled) return null;
  final origin = webOrigin ?? _resolveWebOrigin();
  return AoidOidcAuthStrategy(
    tokenStorage: storage,
    issuer: cfg.issuer,
    clientId: cfg.clientId,
    redirectUri: cfg.redirectUri(origin),
  );
}

/// Maps the flag-gated AOID strategy onto an `authStrategyProvider`
/// override. Returns an empty list when the flag is off
/// ([AoidConfig.enabled]==false), so no override is applied and
/// [AuthNotifier] keeps its package-default null strategy — the legacy
/// email+password path is entirely unchanged.
///
/// Consumer apps call this from their entrypoint:
/// ```dart
/// final container = ProviderContainer(overrides: [
///   tokenStorageProvider.overrideWith((ref) => tokenStorage),
///   ...buildAoidOverrides(AoidConfig.fromEnvironment(), tokenStorage),
/// ]);
/// ```
List<Override> buildAoidOverrides(AoidConfig cfg, TokenStorage storage) {
  final strategy = buildAoidStrategy(cfg, storage);
  if (strategy == null) return const [];
  return [authStrategyProvider.overrideWith((ref) => strategy)];
}
