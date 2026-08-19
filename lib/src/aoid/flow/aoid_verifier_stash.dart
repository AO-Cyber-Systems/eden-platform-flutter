// Persists ONLY the PKCE code_verifier across a full-page redirect on web.
//
// AoidOidcAuthStrategy._pendingPkce is an INSTANCE FIELD cleared in a `finally`
// (aoid_oidc_auth_strategy.dart:65,119-120,151-154). That is correct for the
// popup flow, where the page never unloads — and FATAL for a same-tab
// fallback, where the whole Dart isolate is torn down and the verifier is gone
// on reload. The exchange then fails with `invalid_grant` and nothing in the
// logs says why.
//
// WEB-ONLY BY DESIGN. On native the process survives the hop, so no stash is
// needed and adding one would only widen the attack surface. The native
// binding is therefore [AoidNoVerifierStash], which stores nothing.
//
// # Why `window.sessionStorage` is an ACCEPTABLE exception to D4
//
// the design notes says nothing goes in web storage. This is a DELIBERATE,
// BOUNDED exception, and the bound is the whole justification:
//
//   * ONE key, holding ONE value: the code_verifier. Nothing else may ever be
//     stashed here — not the code, not the state, not a token, not a claim.
//   * `sessionStorage`, so it dies with the tab rather than persisting for the
//     origin. It is explicitly NOT the persistent origin-wide store, which is
//     where `flutter_secure_storage_web` puts ciphertext next to its own AES
//     key and is the exact pattern D4 exists to forbid. (That store's name is
//     a banned literal in this file — the gate is a grep — so it is described
//     rather than spelled.)
//   * A verifier ALONE is useless. RFC 7636 binds it to an authorization code
//     that the attacker does not have, and the code is single-use and
//     short-lived. There is nothing to replay.
//   * Cleared on EVERY terminal outcome, including rejection and cancellation
//     — not just on success.
//
// # What is NOT stashed, and the consequence
//
// The CSRF `state` is deliberately not stashed. After a full-page reload there
// is therefore nothing to compare the returned `state` against, and PKCE's
// verifier binding is what carries the CSRF property on that path (RFC 7636
// §1 — the code is worthless without the verifier). Stashing `state` too would
// buy a redundant check at the price of doubling what a same-tab return leaves
// in web storage. The popup path, where the isolate survives, still compares
// `state` in memory.
//
// RIVERPOD-FREE, like every file under lib/src/aoid/flow/.

import 'package:flutter/foundation.dart' show kIsWeb;

import 'aoid_verifier_stash_stub.dart'
    if (dart.library.js_interop) 'aoid_verifier_stash_web.dart';

/// Single-slot persistence for a PKCE `code_verifier`.
///
/// Implementations hold AT MOST one value under [storageKey]. See the file
/// header for why that bound is the entire security argument.
abstract interface class AoidVerifierStash {
  /// The one and only key any implementation may write.
  ///
  /// Namespaced so it cannot collide with `flutter_web_auth_2`'s own
  /// `flutter-web-auth-2` slot, which lives in a different store entirely.
  static const String storageKey = 'aoid.pkce.code_verifier';

  /// Persist [codeVerifier] for the duration of a full-page redirect.
  void save(String codeVerifier);

  /// The verifier saved before the redirect, or `null` if there is none.
  String? restore();

  /// Drop the stored verifier. Called on EVERY terminal outcome.
  void clear();
}

/// The native binding: stores nothing, because nothing needs storing.
///
/// On iOS/Android/macOS the process survives the browser hop, so the in-memory
/// verifier is still there when the callback arrives. Persisting it anyway
/// would put PKCE material on disk for no benefit at all.
class AoidNoVerifierStash implements AoidVerifierStash {
  const AoidNoVerifierStash();

  @override
  void save(String codeVerifier) {}

  @override
  String? restore() => null;

  @override
  void clear() {}
}

/// A stash over an external `Map`, which is exactly the shape of the browser's
/// session-scoped store: it outlives any single Dart object holding it.
///
/// That property is what makes a same-tab reload testable — construct a fresh
/// stash over the same backing map and you have simulated the reload faithfully
/// rather than approximately.
class AoidMapVerifierStash implements AoidVerifierStash {
  AoidMapVerifierStash(this._backing);

  final Map<String, String> _backing;

  @override
  void save(String codeVerifier) {
    _backing[AoidVerifierStash.storageKey] = codeVerifier;
  }

  @override
  String? restore() => _backing[AoidVerifierStash.storageKey];

  @override
  void clear() {
    _backing.remove(AoidVerifierStash.storageKey);
  }
}

/// The stash for the current platform.
///
/// Web gets the browser's session-scoped store; every other platform gets
/// [AoidNoVerifierStash]. [isWeb] is injectable for the same reason it is on
/// `aoidTokenStoreFor` — `kIsWeb` is a compile-time constant that
/// `flutter test` fixes to `false`, so the web branch is otherwise untestable.
AoidVerifierStash aoidVerifierStashFor({bool isWeb = kIsWeb}) =>
    isWeb ? createPlatformVerifierStash() : const AoidNoVerifierStash();
