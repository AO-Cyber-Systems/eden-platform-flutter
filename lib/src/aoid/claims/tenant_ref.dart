// AOID emits a claim named `tnt` on BOTH the access token and the id_token,
// with DIFFERENT types and DIFFERENT semantics.
//
//   access token  tnt = the SLUG   of the ACTIVE tenant   (follows switching)
//   id_token      tnt = the UUID   of the HOME   tenant   (stable across it)
//
// Source of truth: aoid `internal/oauth/tokens.go` :20-27 (AccessTokenClaims)
// and :41-50 (IDTokenClaims), settled by `internal/oauth/service.go` :928.
//
// WARNING for anyone reading the Go source. The struct-level doc comment
// sitting immediately above `AccessTokenClaims` (tokens.go:15-18) says the
// OPPOSITE — "`tnt` is the tenant UUID string (NOT the slug ...) because access
// tokens are consumed by AOEdge, which routes by UUID". That comment is STALE
// and contradicts the field comment eight lines beneath it. service.go:928
// settles it:
//
//     // tnt = the ACTIVE tenant's slug (target when switching, else home).
//     tenantSlug, err := s.lookupTenantSlug(ctx, activeTenantID)
//
// Read the field comment and service.go, not the struct header. (Correcting the
// Go comment is TRD 50-07's job.)
//
// So the hazard is not hypothetical: the authoritative source contradicts
// itself in adjacent lines, and a reader who trusts the wrong half builds a
// client that sends a UUID where a slug is required. These are therefore two
// Dart 3 `extension type`s over String with NO common supertype, precisely so
// that assigning one where the other is expected is a COMPILE error rather
// than a confusing `invalid_grant` at runtime. They are zero-cost: nothing is
// boxed, the representation is a plain String at runtime.
//
// DO NOT add a common supertype, an `implements` clause, a `String get value`
// on both, an implicit conversion, or a converter between them
// (`toActiveSlug()`, `asHomeId()`, `AoidActiveTenantSlug.from(...)`). A UUID is
// not a slug; the conversion is not merely lossy, it is meaningless. The
// ABSENCE of interchangeability IS the feature. (AOID objective 50, D5.)
//
// Proven by `test/aoid/claims/no_conflation_compile_gate_test.dart`, which runs
// the analyzer over a probe fixture and asserts the diagnostics — including a
// positive control, so the gate cannot pass merely because the probe failed to
// resolve. The properties it pins:
//
//   AoidActiveTenantSlug <- AoidHomeTenantId   invalid_assignment  (ERROR)
//   AoidHomeTenantId     <- AoidActiveTenantSlug invalid_assignment (ERROR)
//   .value on either                            undefined_getter   (ERROR)
//   either <- a raw String                      invalid_assignment (ERROR)
//   Object o = either                           invalid_assignment (ERROR)
//   List<A> <- List<B>, A? <- B?                invalid_assignment (ERROR)
//
// NOTE ON `toString()`. Dart forbids an extension type from declaring a member
// with the same name as an `Object` member — `toString()` included
// (diagnostic: extension_type_declares_member_of_object). Interpolating one of
// these therefore yields the ERASED String: `'$slug'` prints `acme`, not
// `AoidActiveTenantSlug(acme)`. `debugLabel` exists to fill that gap; use it in
// log lines. Do not delete it as redundant, and do not try to add `toString()`
// — it will not compile.
//
// This library imports nothing. It must stay riverpod-free and Flutter-free: it
// sits inside `lib/aoid.dart`'s transitive closure, which
// `test/aoid/riverpod_free_gate_test.dart` walks and enforces.
library;

/// `tnt` as it appears on the AOID **ACCESS token**: the SLUG of the ACTIVE
/// tenant.
///
/// Changes when the user switches tenants. When no active tenant is selected it
/// equals the HOME tenant's slug — still a slug, never the UUID (GID-14
/// byte-compat, `tokens.go:20-27`). So `activeTenant != homeTenant` is **not**
/// a universal invariant; it holds only after a switch.
///
/// Use for: authorization scope, the tenant switcher's current selection, and
/// the `active_tenant=` parameter on refresh. This is the only type that
/// parameter accepts, which is what makes "send the home UUID as active_tenant"
/// unwritable rather than a runtime `invalid_grant`.
extension type const AoidActiveTenantSlug(String slug) {
  /// True when the claim was absent or empty.
  bool get isEmpty => slug.isEmpty;

  /// A log-safe label that names the TYPE as well as the value.
  ///
  /// Needed because an extension type cannot override `toString()`; plain
  /// interpolation yields the bare slug and reads identically to a UUID-bearing
  /// value in a log line.
  String get debugLabel => 'AoidActiveTenantSlug($slug)';
}

/// `tnt` as it appears on the AOID **ID token**: the UUID of the HOME tenant.
///
/// Stable across active-tenant switches — the id_token is an OIDC
/// *authentication* assertion (who you are, and where you live), so it must not
/// follow an *authorization* concern (`tokens.go:41-50`).
///
/// Use for: local user linking / account identity. This is the value AODex keys
/// its user linking on (`aodex/go/internal/auth/aoid/aoid.go:64-68`).
///
/// NEVER use this to scope authorization, and NEVER send it as `active_tenant`
/// — that parameter takes a slug, and this is a UUID.
extension type const AoidHomeTenantId(String uuid) {
  /// True when the claim was absent or empty.
  bool get isEmpty => uuid.isEmpty;

  /// A log-safe label that names the TYPE as well as the value.
  ///
  /// Needed because an extension type cannot override `toString()`; plain
  /// interpolation yields the bare uuid.
  String get debugLabel => 'AoidHomeTenantId($uuid)';
}
