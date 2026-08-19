// Part-barrel OWNED BY the spec — the objective-49 /oauth/native/* no-redirect ceremony client.
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
library;

export '../flow/aoid_native_flow.dart';
export '../transport/aoid_error.dart';
export '../transport/aoid_native_client.dart';
