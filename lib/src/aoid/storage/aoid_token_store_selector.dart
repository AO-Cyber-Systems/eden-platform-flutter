// aoidTokenStoreFor — the ONE place the AOID module decides which token store
// a deployment gets. Kept in its own file so aoid_token_store.dart (the
// interface the spec and the spec import) stays dependency-free.
//
// RIVERPOD-FREE BY CONSTRUCTION (see aoid_token_store.dart's header).

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../auth/token_storage.dart';
import 'aoid_memory_token_store.dart';
import 'aoid_secure_token_store.dart';
import 'aoid_token_store.dart';

/// Returns the token store for a given [posture] and platform.
///
/// **On web the answer is always [AoidMemoryTokenStore], for every posture.**
/// [nativeSecureStorage] is ignored there — a web build cannot opt into
/// persisting a refresh token even by supplying one.
///
/// On native:
/// - [AoidRefreshTokenPosture.deviceKeychain] (Mode B) returns an
///   [AoidSecureTokenStore] wrapping [nativeSecureStorage], which is
///   **required** for that posture. Omitting it throws [ArgumentError] rather
///   than quietly downgrading to memory: a silent downgrade produces a native
///   session that mysteriously stops restoring.
/// - [AoidRefreshTokenPosture.backendHeldCookie] (Mode A) and
///   [AoidRefreshTokenPosture.none] (Mode C) hold no refresh token on any
///   platform, so they get the memory store too.
///
/// [isWeb] defaults to [kIsWeb] and is injectable for the same reason every
/// other constructor in this directory takes it — see AoidSecureTokenStore.
AoidTokenStore aoidTokenStoreFor({
  required AoidRefreshTokenPosture posture,
  bool isWeb = kIsWeb,
  TokenStorage? nativeSecureStorage,
}) {
  // Checked FIRST and unconditionally. Ordering matters: no posture, and no
  // argument the caller can supply, may reach the secure branch on web.
  if (isWeb) return AoidMemoryTokenStore();

  switch (posture) {
    case AoidRefreshTokenPosture.deviceKeychain:
      if (nativeSecureStorage == null) {
        throw ArgumentError.notNull('nativeSecureStorage');
      }
      return AoidSecureTokenStore(nativeSecureStorage, isWeb: isWeb);
    case AoidRefreshTokenPosture.backendHeldCookie:
    case AoidRefreshTokenPosture.none:
      return AoidMemoryTokenStore();
  }
}
