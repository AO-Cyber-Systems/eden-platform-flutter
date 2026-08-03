// Part-barrel OWNED BY TRD 50-02 — secure token storage / the C3 refresh-token exposure fix.
//
// It is exported from lib/eden_platform.dart. Add exports for that TRD's
// files HERE, never to lib/eden_platform.dart: TRDs run in PARALLEL and
// would clobber each other's edits to the shared umbrella barrel.
// (Until TRD 50-24 this part-barrel hung off lib/aoid.dart, which was
// folded into lib/eden_platform.dart and deleted. The collision-avoidance
// reason for these seven files is unchanged.)
//
// Riverpod is ALLOWED here. It was forbidden while lib/aoid.dart had to
// stay importable by a riverpod-3 consumer across a version boundary; AOID
// objective 50 removed that boundary (50-CONTEXT.md D2) and TRD 50-24
// deleted both the barrel and the closure-walking gate that enforced it.
// See doc/riverpod-3-migration.md §3.12.
//
// Filled in by TRD 50-02: the AoidTokenStore family and AoidSession. On web
// none of these can persist a refresh token — AoidMemoryTokenStore throws,
// AoidSecureTokenStore refuses to construct, and aoidTokenStoreFor never picks
// the secure one. See 50-CONTEXT.md D4 / premise correction C3, and the gate at
// test/aoid/storage/web_never_holds_refresh_token_test.dart.
library;

export '../aoid_session.dart';
export '../storage/aoid_memory_token_store.dart';
export '../storage/aoid_secure_token_store.dart';
export '../storage/aoid_token_store.dart';
export '../storage/aoid_token_store_selector.dart';
