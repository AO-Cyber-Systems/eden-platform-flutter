// R-ACL-04 AOID wireup TDD suite.
//
// Proves the flag-gated wiring of AoidOidcAuthStrategy into a consumer app:
//   - flag ON  (AoidConfig.enabled==true)  -> buildAoidStrategy returns a
//     non-null AoidOidcAuthStrategy carrying the configured issuer/clientId
//     and the derived redirect_uri. buildAoidOverrides wraps this into an
//     authStrategyProvider override so AuthNotifier — which already
//     `ref.watch(authStrategyProvider)` — delegates to it.
//   - flag OFF (AoidConfig.enabled==false) -> buildAoidStrategy returns null,
//     so buildAoidOverrides yields NO override and authStrategyProvider keeps
//     its package default (null). Password login is unchanged (zero behavior
//     change is a hard requirement).
//   - bearer forwarding: the PlatformSession the AOID strategy produces
//     carries the AOID access_token verbatim. AuthState.accessToken is
//     literally `session?.accessToken`, and consumer interceptors read
//     `ref.read(authProvider).accessToken`. So the AOID token flows
//     unchanged to every REST + Connect request with no interceptor edits.
//
// Ported from eden-biz-console-login/flutter's aoid_wireup_test.dart.
// Unlike that repo (where eden_platform_flutter's barrel didn't compile
// under `flutter test` at the console's locked pin), this package's own
// barrel compiles cleanly here, so buildAoidOverrides is exercised directly
// through a ProviderContainer below (the console repo could only exercise
// buildAoidStrategy, the pure wiring core).

// Narrow in-package imports (not the eden_platform.dart barrel): the barrel —
// and test_helpers.dart, which imports it — re-export src/networking/*.dart,
// which fails to compile under the CFE against the resolved dio 5.10.0
// (DioExceptionType.transformTimeout). See pkce_generator_test.dart for the
// full note. authStrategyProvider lives in src/auth/auth_provider.dart (no
// networking dependency); the wiring core has none either, so the narrow src/
// imports + a local fake TokenStorage keep this suite green.
import 'package:eden_platform_flutter/src/auth/aoid_config.dart';
import 'package:eden_platform_flutter/src/auth/aoid_oidc_auth_strategy.dart';
import 'package:eden_platform_flutter/src/auth/auth_provider.dart';
import 'package:eden_platform_flutter/src/auth/token_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/aoid_fixtures.dart';
import 'fixtures/fake_aoid_endpoint.dart';

const _issuer = 'https://auth.aocyber.ai';
const _clientId = 'eden-biz-console';
const _webOrigin = 'https://console.biz.aocyber.ai';

/// Map-backed fake TokenStorage local to this suite (avoids test_helpers.dart,
/// which imports the barrel — see note above).
class FakeTokenStorage implements TokenStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> readAccessToken() async => _values['access'];
  @override
  Future<String?> readRefreshToken() async => _values['refresh'];
  @override
  Future<void> writeAccessToken(String? value) async {
    if (value == null) {
      _values.remove('access');
    } else {
      _values['access'] = value;
    }
  }

  @override
  Future<void> writeRefreshToken(String? value) async {
    if (value == null) {
      _values.remove('refresh');
    } else {
      _values['refresh'] = value;
    }
  }

  @override
  Future<void> clear() async => _values.clear();
}

void main() {
  group('buildAoidStrategy — flag gating', () {
    test('flag ON -> non-null AoidOidcAuthStrategy carrying issuer/clientId/'
        'redirect_uri', () {
      const cfg = AoidConfig(
        enabled: true,
        issuer: _issuer,
        clientId: _clientId,
      );

      final strategy =
          buildAoidStrategy(cfg, FakeTokenStorage(), webOrigin: _webOrigin);

      expect(strategy, isNotNull);
      expect(strategy, isA<AoidOidcAuthStrategy>());
      expect(strategy!.issuer, _issuer);
      expect(strategy.clientId, _clientId);
      expect(strategy.redirectUri, '$_webOrigin/auth.html');
    });

    test('flag OFF -> null strategy (password path unchanged)', () {
      const cfg = AoidConfig(
        enabled: false,
        issuer: '',
        clientId: '',
      );

      final strategy =
          buildAoidStrategy(cfg, FakeTokenStorage(), webOrigin: _webOrigin);

      expect(strategy, isNull);
    });

    test('flag ON with empty issuer/clientId fails fast (no silent null)', () {
      const cfg = AoidConfig(enabled: true, issuer: '', clientId: _clientId);

      expect(
        () => buildAoidStrategy(cfg, FakeTokenStorage(), webOrigin: _webOrigin),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('buildAoidOverrides — provider wiring', () {
    test('flag OFF -> empty override list, authStrategyProvider stays null',
        () {
      const cfg = AoidConfig(enabled: false, issuer: '', clientId: '');
      final overrides = buildAoidOverrides(cfg, FakeTokenStorage());

      expect(overrides, isEmpty);

      final container = ProviderContainer(overrides: overrides);
      addTearDown(container.dispose);
      expect(container.read(authStrategyProvider), isNull);
    });

    test('flag ON -> authStrategyProvider resolves to the built strategy',
        () {
      const cfg = AoidConfig(
        enabled: true,
        issuer: _issuer,
        clientId: _clientId,
      );
      final storage = FakeTokenStorage();
      final overrides = buildAoidOverrides(cfg, storage);

      expect(overrides, hasLength(1));

      final container = ProviderContainer(overrides: overrides);
      addTearDown(container.dispose);
      final resolved = container.read(authStrategyProvider);
      expect(resolved, isA<AoidOidcAuthStrategy>());
      expect((resolved as AoidOidcAuthStrategy).issuer, _issuer);
      expect(resolved.clientId, _clientId);
    });
  });

  group('bearer forwarding', () {
    test(
        'AOID session carries the AOID access_token verbatim — the exact value '
        'AuthState.accessToken surfaces to consumer interceptors', () async {
      const aoidAccess = 'aoid-access-token-forwarded-unchanged';
      const aoidRefresh = 'aoid-refresh-token-xyz';

      final fake = FakeAoidEndpoint(issuer: _issuer)
        ..tokenAccessToken = aoidAccess
        ..tokenRefreshToken = aoidRefresh;
      final storage = FakeTokenStorage();
      await storage.writeRefreshToken(fixtureRefreshToken());

      // The strategy a consumer app wires via buildAoidStrategy — here built
      // with the fake AOID endpoint so restoreSession's refresh_token grant
      // is deterministic.
      final strategy = AoidOidcAuthStrategy(
        tokenStorage: storage,
        issuer: _issuer,
        clientId: _clientId,
        redirectUri: '$_webOrigin/auth.html',
        httpClient: fake.client,
      );

      final session = await strategy.restoreSession();

      expect(session, isNotNull);
      // AuthState.accessToken is defined as `session?.accessToken`; consumer
      // interceptors read `ref.read(authProvider).accessToken`. So this
      // value is exactly what is forwarded as the Bearer token.
      expect(session!.accessToken, aoidAccess);
      expect(session.cookieBound, isFalse);
    });
  });
}
