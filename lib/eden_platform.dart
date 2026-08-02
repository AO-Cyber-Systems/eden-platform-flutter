export 'src/platform_config.dart';
export 'src/analytics/analytics_provider.dart';
// AOID module (AOID objective 50 TRD 50-01). The AOID surface moved from
// src/auth/{pkce_generator,aoid_config,aoid_oidc_auth_strategy}.dart into
// lib/src/aoid{,_riverpod}/ and is re-exported here through its two barrels,
// so this file's exported SYMBOL SET is unchanged — every existing consumer
// compiles untouched. Verified by test/aoid/eden_platform_surface_test.dart,
// which names each relocated symbol; a diffstat cannot prove this.
//
// aoid.dart is the riverpod-FREE half (importable by a flutter_riverpod 3.x
// consumer such as AODex); aoid_riverpod.dart is the riverpod-2 adapter.
// Consumers of THIS barrel are riverpod-2 already, so they get both.
export 'aoid.dart';
export 'aoid_riverpod.dart';
export 'src/auth/auth_provider.dart';
export 'src/auth/auth_strategy.dart';
export 'src/auth/login_screen.dart';
export 'src/auth/secure_token_storage.dart';
export 'src/auth/signup_screen.dart';
export 'src/auth/social_auth_service.dart';
export 'src/auth/social_login_providers.dart';
// REMOVED (AOID objective 50, TRD 50-10 / SDK-08 / D6):
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
// Riverpod patterns — donated from AODex (pagination + mutation). See
// src/providers/README.md for usage and migration guide.
export 'src/providers/paginated_async_notifier.dart';
export 'src/providers/mutation_notifier.dart';
// Riverpod ↔ eden-ui-flutter bridge helpers.
export 'src/widgets/eden_async_snapshot_riverpod.dart';

// Shared Sentry init + PII scrubbers (opsCluster obj-31 TRD 31-08 / TELE-03).
// Every AOCyber Flutter app calls initSentry from here so the scrubbers exist
// in exactly ONE place — four copies of a privacy control is the failure mode
// this replaces.
export 'src/observability/sentry_init.dart';
