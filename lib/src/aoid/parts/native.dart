// Part-barrel OWNED BY TRD 50-08 — the objective-49 /oauth/native/* no-redirect ceremony client.
//
// It is exported from lib/aoid.dart. Add exports for that TRD's files HERE,
// never to lib/aoid.dart: waves 2-4 run TRDs in PARALLEL and would clobber
// each other's edits to the shared umbrella barrel.
//
// Anything exported from here MUST stay riverpod-free — it lands inside
// lib/aoid.dart's transitive closure, which
// test/aoid/riverpod_free_gate_test.dart walks and enforces.
library;

export '../transport/aoid_error.dart';
export '../transport/aoid_native_client.dart';
