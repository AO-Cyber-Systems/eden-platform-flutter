// Part-barrel — the sealed AoidLoginForm widgets (D3 — app code never sees the password).
//
// It is exported from lib/eden_platform.dart. Add exports for that area's
// files HERE, never to lib/eden_platform.dart: parallel work would
// clobber each other's edits to the shared umbrella barrel.
// (This part-barrel previously hung off lib/aoid.dart, which was
// folded into lib/eden_platform.dart and deleted. The collision-avoidance
// reason for these seven files is unchanged.)
//
// Riverpod is ALLOWED here. It was forbidden while lib/aoid.dart had to
// stay importable by a riverpod-3 consumer across a version boundary; that
// boundary is gone, and both the barrel and the closure-walking gate that
// enforced it were deleted with it.
// See doc/riverpod-3-migration.md §3.12.
//
// The forms below are SEALED: they own their own text
// controllers and expose no API through which app-owned Dart could obtain the
// plaintext credential. What is NOT exported matters as much as what is —
// their State classes are private precisely so no app-declarable key can name
// them. Gate: test/aoid/widgets/sealed_form_no_leak_test.dart.
library;

export '../widgets/aoid_login_form.dart';
export '../widgets/aoid_login_theme.dart';
export '../widgets/aoid_mfa_form.dart';
