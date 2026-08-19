// Part-barrel — the deny-by-default tenant switch.
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
// Nothing below it uses riverpod, though, and that is deliberate rather than
// vestigial: `AoidTenantController` is a plain `ChangeNotifier` so a consumer
// on any state-management stack — and the AODex BFF mirror — can drive the
// switch without inheriting riverpod 3's automatic provider retry (see
// `aoidTenantSwitchRetry` in tenant/aoid_tenant_error.dart).
library;

export '../tenant/aoid_refresh_single_flight.dart';
export '../tenant/aoid_tenant_controller.dart';
export '../tenant/aoid_tenant_error.dart';
export '../transport/aoid_token_client.dart';
