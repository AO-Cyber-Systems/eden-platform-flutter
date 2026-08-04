// Part-barrel OWNED BY TRD 50-11 — the sealed AoidLoginForm widgets (D3 — app code never sees the password).
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
//
// The forms below are SEALED (50-CONTEXT.md D3): they own their own text
// controllers and expose no API through which app-owned Dart could obtain the
// plaintext credential. What is NOT exported matters as much as what is —
// their State classes are private precisely so no app-declarable key can name
// them. Gate: test/aoid/widgets/sealed_form_no_leak_test.dart.
library;

export '../widgets/aoid_login_form.dart';
export '../widgets/aoid_login_theme.dart';
export '../widgets/aoid_mfa_form.dart';
