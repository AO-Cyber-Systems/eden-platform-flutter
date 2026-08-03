// Riverpod-2 wiring for AoidConfig — the half of the old
// lib/src/auth/aoid_config.dart that names providers.
//
// Split out by AOID objective 50 TRD 50-01, when the plain [AoidConfig] value
// class had to stay riverpod-free in lib/src/aoid/aoid_config.dart so that a
// riverpod-3 consumer could import it across a version boundary, while
// everything here needed riverpod 2. Both halves now ship from the single
// `package:eden_platform_flutter/eden_platform.dart` entrypoint: TRD 50-24
// folded the two top-level AOID barrels in and deleted them, because the
// boundary they routed around was removed by the riverpod 3 alignment
// (50-CONTEXT.md D2). The directory split remains as a LAYERING marker only.
//
// Nothing under lib/src/aoid/ should import this file — the core should not
// depend on the adapter layer. That was previously enforced by
// test/aoid/riverpod_free_gate_test.dart, which TRD 50-24 deleted along with
// the firewall it guarded; the layering is now a convention. See
// doc/riverpod-3-migration.md §3.12.
//
// Behaviour is unchanged from the pre-split file; only the location moved.

import 'package:flutter_riverpod/flutter_riverpod.dart';
// riverpod 3.x split the old single barrel into THREE: flutter_riverpod.dart
// (core), legacy.dart (StateNotifier & friends) and misc.dart. `Override` — the
// return type of buildAoidOverrides below — moved into misc.dart. STAGE A of
// AOID objective 50's riverpod alignment (50-CONTEXT.md D2, TRD 50-06).
//
// PERMANENT, and deliberately so — resolved by TRD 50-24 (Stage C), which was
// the ticket this import's old "TEMPORARY" marker pointed at. It is NOT a Stage
// A shim: `Override` is not deprecated and has no Notifier-API replacement, so
// there is nothing here to retire. Every actual legacy.dart shim is gone (Stage
// B), and the marker was removed so the objective-level sweep for surviving
// Stage A residue — `grep -rn TEMPORARY lib/ | grep -i riverpod` — reports the
// truth rather than this false positive. See doc/riverpod-3-migration.md §3.12.
import 'package:flutter_riverpod/misc.dart';

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
