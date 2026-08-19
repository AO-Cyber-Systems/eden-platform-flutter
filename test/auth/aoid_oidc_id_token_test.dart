// COMPANION-AV05-AOID-JIT-05 — AOID id_token capture + surface TDD suite.
//
// Test list (the design notes §"Test list", eden-platform-flutter items 1–3):
//   1. token response WITH an id_token ⇒ session.idToken == that value. [MH-3]
//   2. token response WITHOUT an id_token ⇒ session.idToken == null (no
//      crash). [backward-compat]
//   3. AuthState.idToken == session?.idToken.
//
// Narrow in-package imports (NOT the eden_platform.dart barrel) — see
// aoid_oidc_auth_strategy_test.dart for why auth suites avoid the barrel (it
// re-exports src/networking/*.dart, which fails to compile under the CFE
// against the resolved dio). auth_provider.dart is the handwritten AuthState
// only and pulls no networking, so importing it directly is safe.
import 'package:eden_platform_flutter/src/aoid_riverpod/aoid_oidc_auth_strategy.dart';
import 'package:eden_platform_flutter/src/auth/auth_provider.dart';
import 'package:eden_platform_flutter/src/auth/auth_strategy.dart';
import 'package:eden_platform_flutter/src/auth/token_storage.dart';
import 'package:eden_platform_flutter/src/models/platform_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/aoid_fixtures.dart';
import 'fixtures/fake_aoid_endpoint.dart';

const _issuer = 'https://auth.aocyber.ai';
const _clientId = 'eden-biz-console';
const _redirectUri = 'https://console.biz.aocyber.ai/auth.html';

/// Map-backed fake TokenStorage local to this suite (mirrors the one in
/// aoid_oidc_auth_strategy_test.dart — avoids test_helpers.dart / the barrel).
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

/// Drives initiateLogin end-to-end against [fake], echoing the generated CSRF
/// state so the exchange succeeds, and returns the resulting bearer session.
Future<PlatformSession> _login(FakeAoidEndpoint fake) async {
  final strategy = AoidOidcAuthStrategy(
    tokenStorage: FakeTokenStorage(),
    issuer: _issuer,
    clientId: _clientId,
    redirectUri: _redirectUri,
    httpClient: fake.client,
    authorize: (
        {required String url, required String callbackUrlScheme}) async {
      final generatedState = Uri.parse(url).queryParameters['state']!;
      return fakeAuthorize(
        redirectUri: _redirectUri,
        returnedState: generatedState,
        code: 'FAKE_CODE',
      );
    },
  );
  final result = await strategy.initiateLogin({});
  expect(result, isA<Authenticated>(),
      reason: 'exchange should succeed with echoed state + fixture tokens');
  return (result as Authenticated).session;
}

PlatformUser _fixtureUser() => const PlatformUser(
      id: 'u',
      email: '',
      displayName: '',
      isActive: true,
    );

void main() {
  group('AoidOidcAuthStrategy — id_token capture (item 1)', () {
    test('token response WITH id_token ⇒ session.idToken == that value',
        () async {
      const knownIdToken = 'known-id-token-value-abc123';
      final fake = FakeAoidEndpoint(issuer: _issuer)
        ..tokenIdToken = knownIdToken;

      final session = await _login(fake);

      expect(session.idToken, knownIdToken);
      // Access/refresh still captured (existing behaviour byte-unchanged).
      expect(session.accessToken, fixtureAccessToken());
      expect(session.refreshToken, fixtureRefreshToken());
      expect(session.cookieBound, isFalse);
    });
  });

  group('AoidOidcAuthStrategy — id_token absent (item 2, backward-compat)', () {
    test('token response WITHOUT id_token ⇒ session.idToken == null (no crash)',
        () async {
      final fake = FakeAoidEndpoint(issuer: _issuer)..omitIdToken = true;

      final session = await _login(fake);

      expect(session.idToken, isNull);
      // Still a fully valid bearer session — access/refresh present.
      expect(session.accessToken, fixtureAccessToken());
      expect(session.refreshToken, fixtureRefreshToken());
    });
  });

  group('AuthState.idToken (item 3)', () {
    test('== session.idToken when the session carries one', () {
      const idToken = 'auth-state-id-token-xyz';
      final session = PlatformSession(
        accessToken: 'a',
        refreshToken: 'r',
        user: _fixtureUser(),
        idToken: idToken,
      );
      final state = AuthState.authenticated(session);
      expect(state.idToken, idToken);
    });

    test('== null when the session has no id_token', () {
      final session = PlatformSession(
        accessToken: 'a',
        refreshToken: 'r',
        user: _fixtureUser(),
      );
      final state = AuthState.authenticated(session);
      expect(state.idToken, isNull);
    });

    test('== null when unauthenticated (no session)', () {
      const state = AuthState.unauthenticated();
      expect(state.idToken, isNull);
    });
  });
}
