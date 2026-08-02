// Part-barrel OWNED BY TRD 50-03 — the tnt claim types (D5 — active-tenant SLUG vs home-tenant UUID).
//
// It is exported from lib/aoid.dart. Add exports for that TRD's files HERE,
// never to lib/aoid.dart: waves 2-4 run TRDs in PARALLEL and would clobber
// each other's edits to the shared umbrella barrel.
//
// Empty today. An empty `library;` is legal Dart and exports nothing, so
// lib/aoid.dart compiles now and 50-03 fills this in without touching a
// shared file.
//
// Anything exported from here MUST stay riverpod-free — it lands inside
// lib/aoid.dart's transitive closure, which
// test/aoid/riverpod_free_gate_test.dart walks and enforces.
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
