// Riverpod-2 wiring for AoidConfig — the half of the old
// lib/src/auth/aoid_config.dart that names providers.
//
// Split out by AOID objective 50 TRD 50-01. The plain [AoidConfig] value class
// stayed riverpod-free in lib/src/aoid/aoid_config.dart so that
// `package:eden_platform_flutter/aoid.dart` can be imported by a
// flutter_riverpod 3.x consumer; everything here needs flutter_riverpod 2.x
// and therefore lives behind `package:eden_platform_flutter/aoid_riverpod.dart`.
//
// Nothing under lib/src/aoid/ may import this file — the core must not depend
// on the adapter layer. test/aoid/riverpod_free_gate_test.dart enforces both
// directions.
//
// Behaviour is unchanged from the pre-split file; only the location moved.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../aoid/aoid_config.dart';
import '../auth/auth_provider.dart';
import '../auth/token_storage.dart';
import 'aoid_oidc_auth_strategy.dart';

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
/// `AuthNotifier` keeps its package-default null strategy — the legacy
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
