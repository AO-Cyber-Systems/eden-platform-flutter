// Part-barrel OWNED BY TRD 50-09 — the three deployment modes (D4 — BFF / public+PKCE / same-origin).
//
// It is exported from lib/aoid.dart. Add exports for that TRD's files HERE,
// never to lib/aoid.dart: waves 2-4 run TRDs in PARALLEL and would clobber
// each other's edits to the shared umbrella barrel.
//
// Empty today. An empty `library;` is legal Dart and exports nothing, so
// lib/aoid.dart compiles now and 50-09 fills this in without touching a
// shared file.
//
// Anything exported from here MUST stay riverpod-free — it lands inside
// lib/aoid.dart's transitive closure, which
// test/aoid/riverpod_free_gate_test.dart walks and enforces.
library;
