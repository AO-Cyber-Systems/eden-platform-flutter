// Part-barrel OWNED BY the spec — secure token storage / the C3 refresh-token exposure fix.
//
// It is exported from lib/eden_platform.dart. Add exports for that the spec's
// files HERE, never to lib/eden_platform.dart: TRDs run in PARALLEL and
// would clobber each other's edits to the shared umbrella barrel.
// (Until the spec this part-barrel hung off lib/aoid.dart, which was
// folded into lib/eden_platform.dart and deleted. The collision-avoidance
// reason for these seven files is unchanged.)
//
// Riverpod is ALLOWED here. It was forbidden while lib/aoid.dart had to
// stay importable by a riverpod-3 consumer across a version boundary; AOID
// the issuer removed that boundary and the spec
// deleted both the barrel and the closure-walking gate that enforced it.
// See doc/riverpod-3-migration.md §3.12.
//
// Filled in by the spec: the AoidTokenStore family and AoidSession. On web
// none of these can persist a refresh token — AoidMemoryTokenStore throws,
// AoidSecureTokenStore refuses to construct, and aoidTokenStoreFor never picks
// the secure one. See the design notes / premise correction C3, and the gate at
// test/aoid/storage/web_never_holds_refresh_token_test.dart.
library;

export '../aoid_session.dart';
export '../storage/aoid_memory_token_store.dart';
export '../storage/aoid_secure_token_store.dart';
export '../storage/aoid_token_store.dart';
export '../storage/aoid_token_store_selector.dart';
