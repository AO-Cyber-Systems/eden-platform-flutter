/// The AOID riverpod-2 ADAPTER barrel.
///
/// Everything here needs `flutter_riverpod ^2.6.1` — the version this package
/// pins — either directly or by implementing an interface that riverpod-2
/// `AuthNotifier` (a `StateNotifier`) drives. A consumer resolving
/// flutter_riverpod 3.x must NOT import this file; it should import
/// `package:eden_platform_flutter/aoid.dart` instead, which is riverpod-free
/// by enforced invariant.
///
/// Layering is one-directional: this barrel may depend on `lib/src/aoid/`,
/// but NOTHING under `lib/src/aoid/` may import `lib/src/aoid_riverpod/`.
/// The strategy consumes the core, never the reverse.
/// test/aoid/riverpod_free_gate_test.dart enforces both directions.
///
/// TRANSITIONAL, exactly like lib/aoid.dart. AOID objective 50 absorbs the
/// full riverpod 2 -> 3 alignment (50-CONTEXT D2) rather than living behind
/// the split permanently; TRD 50-24 folds this barrel and aoid.dart back into
/// eden_platform.dart and deletes them.
library;

export 'src/aoid_riverpod/aoid_config_riverpod.dart';
export 'src/aoid_riverpod/aoid_oidc_auth_strategy.dart';
