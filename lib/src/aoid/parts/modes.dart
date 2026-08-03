// Part-barrel OWNED BY TRD 50-09 — the three deployment modes (D4 — BFF / public+PKCE / same-origin).
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
library;

export '../mode/aoid_code_sink.dart';
export '../mode/aoid_deployment_mode.dart';
export '../mode/http_bff_code_sink.dart';
