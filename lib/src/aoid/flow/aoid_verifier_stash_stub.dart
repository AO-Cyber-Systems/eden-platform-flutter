// Native/VM half of the conditional import in aoid_verifier_stash.dart.
//
// Selected on every platform EXCEPT web. `dart:js_interop` is web-only — it
// does not compile on the Dart VM at all ("Dart library 'dart:js_interop' is
// not available on this platform"), which is why the browser binding cannot
// live in the same file and this pair exists. Same shape as
// lib/src/networking/websocket_factory.dart, the repo's existing precedent.

import 'aoid_verifier_stash.dart';

/// On native the process survives the browser hop, so there is nothing to
/// persist and nothing to attack.
AoidVerifierStash createPlatformVerifierStash() => const AoidNoVerifierStash();
