// Part-barrel OWNED BY TRD 50-02 — secure token storage / the C3 refresh-token exposure fix.
//
// It is exported from lib/aoid.dart. Add exports for that TRD's files HERE,
// never to lib/aoid.dart: waves 2-4 run TRDs in PARALLEL and would clobber
// each other's edits to the shared umbrella barrel.
//
// Anything exported from here MUST stay riverpod-free — it lands inside
// lib/aoid.dart's transitive closure, which
// test/aoid/riverpod_free_gate_test.dart walks and enforces.
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
