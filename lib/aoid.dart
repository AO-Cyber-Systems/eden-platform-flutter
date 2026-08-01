/// The AOID module barrel — DELIBERATELY riverpod-FREE.
///
/// This barrel exists for COMPATIBILITY, not tree shaking. Dart's AOT tree
/// shaker already drops unreferenced code, so a separate barrel buys nothing
/// there. What it buys is this: a consumer resolving flutter_riverpod 3.x can
/// import this file and the analyzer will never resolve a StateNotifier
/// reference, because nothing in this barrel's transitive closure names one.
/// In riverpod 3.x StateNotifier moved to flutter_riverpod/legacy.dart, and
/// eden's AuthNotifier is built on it.
///
/// aodex/flutter resolves flutter_riverpod 3.x and consumes THIS barrel. If
/// you add an export that pulls in riverpod, AODex stops compiling.
/// test/aoid/riverpod_free_gate_test.dart enforces it by walking this file's
/// transitive import/export closure — not by grepping one directory, which
/// would miss riverpod reached indirectly through `../auth/`.
///
/// Same reasoning, same package: see lib/networking.dart:3-10. Keep the two
/// barrels INDEPENDENT — aoid.dart must not be re-exported from
/// networking.dart, or a future AOID dependency silently becomes a networking
/// dependency for the aofamily apps.
///
/// TRANSITIONAL, not a permanent architectural boundary. AOID objective 50
/// absorbs the full riverpod 2 -> 3 alignment (50-CONTEXT D2), and TRD 50-24
/// folds this barrel and aoid_riverpod.dart back into eden_platform.dart and
/// deletes them once auth/company/nav are on the 3.x AnnotationNotifier API.
/// The split earns its keep until then; do not build long-lived API on the
/// assumption that these two entrypoints stay separate.
library;

export 'src/aoid/aoid_config.dart';
export 'src/aoid/pkce.dart';
export 'src/aoid/transport/aoid_endpoints.dart';

// ONE PART-BARREL PER DOWNSTREAM TRD. Waves 2-4 run TRDs in PARALLEL, and if
// they all appended to this file they would clobber each other's exports.
// Each owns exactly one file below and NEVER edits this one.
//   storage  -> 50-02   claims  -> 50-03   native   -> 50-08
//   modes    -> 50-09   widgets -> 50-11   redirect -> 50-12
//   tenant   -> 50-13
export 'src/aoid/parts/claims.dart';
export 'src/aoid/parts/modes.dart';
export 'src/aoid/parts/native.dart';
export 'src/aoid/parts/redirect.dart';
export 'src/aoid/parts/storage.dart';
export 'src/aoid/parts/tenant.dart';
export 'src/aoid/parts/widgets.dart';
