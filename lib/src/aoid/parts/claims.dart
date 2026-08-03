// Part-barrel OWNED BY TRD 50-03 — the tnt claim types (D5 — active-tenant SLUG vs home-tenant UUID).
//
// It is exported from lib/eden_platform.dart. Add exports for that TRD's
// files HERE, never to lib/eden_platform.dart: TRDs run in PARALLEL and
// would clobber each other's edits to the shared umbrella barrel.
// (Until TRD 50-24 this part-barrel hung off lib/aoid.dart, which was
// folded into lib/eden_platform.dart and deleted. The collision-avoidance
// reason for these seven files is unchanged.)
//
// Empty today. An empty `library;` is legal Dart and exports nothing, so
// lib/eden_platform.dart compiles now and 50-03 fills this in without touching a
// shared file.
//
// Riverpod is ALLOWED here. It was forbidden while lib/aoid.dart had to
// stay importable by a riverpod-3 consumer across a version boundary; AOID
// objective 50 removed that boundary (50-CONTEXT.md D2) and TRD 50-24
// deleted both the barrel and the closure-walking gate that enforced it.
// See doc/riverpod-3-migration.md §3.12.
//
// Filled in by TRD 50-03: the two NON-INTERCHANGEABLE `tnt` types and the two
// unverified claim decoders. Access-token `tnt` is the ACTIVE tenant's SLUG;
// id_token `tnt` is the HOME tenant's UUID. Conflating them is a COMPILE
// error by construction — see lib/src/aoid/claims/tenant_ref.dart's header and
// test/aoid/claims/no_conflation_compile_gate_test.dart. Do not add a type here
// that carries a single, untyped `tnt`.
library;

export '../claims/aoid_claims.dart';
export '../claims/tenant_ref.dart';
