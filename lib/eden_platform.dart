// The FULL entrypoint for `eden_platform_flutter` — auth, company, navigation,
// settings, entitlements, shell, networking, observability and the AOID SDK.
//
// Prefer this import. Since AOID migrated all
// five notifiers from riverpod 2's StateNotifier to the 3.x Notifier API, taking
// the full surface no longer costs a riverpod version conflict — which is the
// reason the narrower entrypoints existed in the first place. See
// doc/riverpod-3-migration.md.
//
// `lib/networking.dart` REMAINS a supported, narrower entrypoint and must not be
// deleted as redundant: four consumer packages import only it, and it carries
// the dio re-export that politihub's APP-06 grep gate depends on — a gate that
// lives in another repository and cannot fail in this one. The two surfaces are
// NOT nested in either direction; see that file's header.

export 'src/platform_config.dart';
export 'src/analytics/analytics_provider.dart';
// ─── The AOID SDK ────────────────────────────────────────────────────────────
//
// The AOID surface is part of this single entrypoint. It used to sit behind two
// top-level barrels — `lib/aoid.dart` (riverpod-FREE) and `lib/aoid_riverpod.dart`
// (the riverpod-2 adapter) — which later work FOLDED IN HERE and deleted.
//
// That split had exactly one cause: `AoidOidcAuthStrategy` depends on riverpod,
// and while this package pinned riverpod 2 a riverpod-3 consumer (AODex) could
// not reach the AOID client through a riverpod-2 barrel. It was a VERSION
// BOUNDARY, not a layering decision, and the original split's own headers said so — both
// barrels were labelled TRANSITIONAL and named the follow-up work that would
// retire them. Stages A–C removed the boundary, so the split
// was left defending nothing while still taxing every consumer with a choice of
// entrypoint. See doc/riverpod-3-migration.md §3.12.
//
// `lib/src/aoid/**` and `lib/src/aoid_riverpod/**` STAY — only the two
// top-level barrels went. In particular the seven part-barrels under
// `lib/src/aoid/parts/` exist so that TRDs running in PARALLEL each own one
// file instead of colliding on this one, and they are still doing that job.
//
// The full AOID surface resolving from this file alone is asserted by
// test/aoid/eden_platform_surface_test.dart; a diffstat cannot prove it.
export 'src/aoid/aoid_config.dart';
export 'src/aoid/pkce.dart';
export 'src/aoid/transport/aoid_endpoints.dart';
// One part-barrel per downstream area (carried over from lib/aoid.dart):
export 'src/aoid/parts/claims.dart';
export 'src/aoid/parts/modes.dart';
export 'src/aoid/parts/native.dart';
export 'src/aoid/parts/redirect.dart';
export 'src/aoid/parts/storage.dart';
export 'src/aoid/parts/tenant.dart';
export 'src/aoid/parts/widgets.dart';
// The riverpod-facing half. Formerly lib/aoid_riverpod.dart.
export 'src/aoid_riverpod/aoid_config_riverpod.dart';
export 'src/aoid_riverpod/aoid_oidc_auth_strategy.dart';
// ─────────────────────────────────────────────────────────────────────────────
export 'src/auth/auth_provider.dart';
export 'src/auth/auth_strategy.dart';
export 'src/auth/login_screen.dart';
export 'src/auth/secure_token_storage.dart';
export 'src/auth/signup_screen.dart';
export 'src/auth/social_auth_service.dart';
export 'src/auth/social_login_providers.dart';
// REMOVED:
// `export 'src/auth/sso_auth_service.dart'`. SSOAuthService read access_token
// and refresh_token out of a desktop loopback callback URL and shelled out via
// Process.run. Zero callers across ~/dev, so it was deleted, not repaired.
// BREAKING for anyone importing the symbol — the grep proved there is nobody.
export 'src/auth/token_storage.dart';
export 'src/api/platform_repository.dart';
export 'src/company/company_provider.dart';
export 'src/company/company_switcher.dart';
export 'src/models/platform_models.dart';
export 'src/navigation/sidebar.dart';
export 'src/navigation/nav_provider.dart';
export 'src/settings/settings_screen.dart';
export 'src/settings/settings_provider.dart';
export 'src/platform_shell.dart';
export 'src/entitlements/entitlements_models.dart';
export 'src/entitlements/entitlements_repository.dart';
export 'src/entitlements/entitlements_provider.dart';
export 'src/entitlements/feature_gate.dart';
export 'src/entitlements/quota_bar.dart';
export 'src/entitlements/plan_badge.dart';
// Networking — donated from AODex (gold-standard dio_client). See
// src/networking/README.md for the full surface and migration guide.
export 'src/networking/api_exception.dart';
export 'src/networking/auth_audit_interceptor.dart';
export 'src/networking/auth_interceptor.dart';
export 'src/networking/cookie_jar_helper.dart'
    show initCookieJar, initCookieJarWeb, cookieJar;
export 'src/networking/dio_client_config.dart';
export 'src/networking/dio_client_factory.dart';
export 'src/networking/login_path_rule.dart';
export 'src/networking/retry_interceptor.dart';
export 'src/networking/websocket_factory.dart';
// Connect transport helpers — upstreamed from eden-biz (see networking/README.md).
export 'src/networking/connect_bearer_interceptor.dart';
export 'src/networking/connect_cookie_interceptor.dart'
    show connectCookieInterceptor;
export 'src/networking/proactive_refresh.dart';
// The same dio re-export `networking.dart` carries.
//
// Why: before this, a consumer on the FULL barrel that wrote its own
// `Interceptor` or a fake `HttpClientAdapter` had to either import package:dio
// directly — which trips politihub's APP-06 grep gate (`^import
// 'package:(http|dio)/`) — or additionally import `networking.dart` purely to
// borrow the type names. Neither is a good answer, and the second is the sort of
// incidental double-import that made the two entrypoints look nested when they
// are not.
//
// This is PURELY ADDITIVE: nothing was removed from this barrel to make room,
// and it creates no ambiguity for a consumer importing BOTH entrypoints, because
// both re-export the SAME declarations from package:dio/dio.dart (Dart only
// reports a conflict when one name resolves to two DIFFERENT declarations).
//
// Keep this list in sync with lib/networking.dart. It is duplicated rather than
// chained deliberately: `export 'networking.dart'` would make the dio symbols
// transitive for that file's four consumers, and networking.dart's own comment
// records that the APP-06 gate does not detect transitive exports.
export 'package:dio/dio.dart'
    show Dio, Interceptor, RequestOptions, RequestInterceptorHandler,
         ResponseInterceptorHandler, ErrorInterceptorHandler, Response,
         DioException, HttpClientAdapter, ResponseBody,
         Options;
// Riverpod patterns — donated from AODex (pagination + mutation). See
// src/providers/README.md for usage and migration guide.
export 'src/providers/paginated_async_notifier.dart';
export 'src/providers/mutation_notifier.dart';
// Riverpod ↔ eden-ui-flutter bridge helpers.
export 'src/widgets/eden_async_snapshot_riverpod.dart';

// Shared Sentry init + PII scrubbers (opsCluster).
// Every AOCyber Flutter app calls initSentry from here so the scrubbers exist
// in exactly ONE place — four copies of a privacy control is the failure mode
// this replaces.
export 'src/observability/sentry_init.dart';
