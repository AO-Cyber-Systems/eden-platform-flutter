// Part-barrel — the tnt claim types (D5 — active-tenant SLUG vs home-tenant UUID).
//
// It is exported from lib/eden_platform.dart. Add exports for that area's
// files HERE, never to lib/eden_platform.dart: parallel work would
// clobber each other's edits to the shared umbrella barrel.
// (This part-barrel previously hung off lib/aoid.dart, which was
// folded into lib/eden_platform.dart and deleted. The collision-avoidance
// reason for these seven files is unchanged.)
//
// Empty today. An empty `library;` is legal Dart and exports nothing, so
// lib/eden_platform.dart compiles now and this can be filled in without
// touching a shared file.
//
// Riverpod is ALLOWED here. It was forbidden while lib/aoid.dart had to
// stay importable by a riverpod-3 consumer across a version boundary; that
// boundary is gone, and both the barrel and the closure-walking gate that
// enforced it were deleted with it.
// See doc/riverpod-3-migration.md §3.12.
//
// Contains: the two NON-INTERCHANGEABLE `tnt` types and the two
// unverified claim decoders. Access-token `tnt` is the ACTIVE tenant's SLUG;
// id_token `tnt` is the HOME tenant's UUID. Conflating them is a COMPILE
// error by construction — see lib/src/aoid/claims/tenant_ref.dart's header and
// test/aoid/claims/no_conflation_compile_gate_test.dart. Do not add a type here
// that carries a single, untyped `tnt`.
library;

export '../claims/aoid_claims.dart';
export '../claims/tenant_ref.dart';
