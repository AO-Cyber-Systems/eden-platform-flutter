// R-ACL-03 AoidOidcAuthStrategy TDD suite.
//
// Test list (see AOID-CONSOLE-LOGIN-03-TRD.md, ported from
// eden-biz-console-login/flutter):
// Happy:
//   (a) initiateLogin({}) builds authorize URL per AOID frozen contract §1.
//   (b) fake authorize + fake token endpoint -> Authenticated bearer session.
//   (c) restoreSession() with persisted refresh token -> refreshed bearer session.
// Edge:
//   - restoreSession() null when no refresh token.
//   - logout() best-effort /oauth/revoke, tolerates network failure, clears
//     in-memory PKCE state.
//   - completeLogin(...) -> Failed('not supported').
// Failure:
//   - callback state != generated -> Failed (CSRF guard), NO token POST fired.
//   - token non-200 -> Failed.
//   - authorize throws/cancel -> Failed.
// Bearer-wiring:
//   - session.accessToken == fixture access token && session.cookieBound == false.

// Narrow in-package imports (not the eden_platform.dart barrel): the barrel —
// and test_helpers.dart, which imports it — re-export src/networking/*.dart,
// which fails to compile under the CFE against the resolved dio 5.10.0
// (DioExceptionType.transformTimeout). See pkce_generator_test.dart for the
// full note. The auth strategy contract has no networking dependency, so the
// narrow src/ imports + a local fake TokenStorage keep this suite green.
import 'package:eden_platform_flutter/src/aoid_riverpod/aoid_oidc_auth_strategy.dart';
import 'package:eden_platform_flutter/src/auth/auth_strategy.dart';
import 'package:eden_platform_flutter/src/auth/token_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/aoid_fixtures.dart';
import 'fixtures/fake_aoid_endpoint.dart';

const _issuer = 'https://auth.aocyber.ai';
const _clientId = 'eden-biz-console';
const _redirectUri = 'https://console.biz.aocyber.ai/auth.html';

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
  group('AoidOidcAuthStrategy.initiateLogin — authorize URL', () {
    test('builds authorize URL per AOID frozen contract §1', () async {
      Uri? capturedUrl;
      String? capturedScheme;

      final strategy = AoidOidcAuthStrategy(
        tokenStorage: FakeTokenStorage(),
        issuer: _issuer,
        clientId: _clientId,
        redirectUri: _redirectUri,
        httpClient: FakeAoidEndpoint(issuer: _issuer).client,
        authorize: (
            {required String url, required String callbackUrlScheme}) async {
          capturedUrl = Uri.parse(url);
          capturedScheme = callbackUrlScheme;
          // This test only inspects the outgoing authorize request; throw to
          // short-circuit the rest of initiateLogin (covered by later tests).
          throw Exception('authorize-url-test: intentional stop');
        },
      );

      await strategy.initiateLogin({});

      expect(capturedUrl, isNotNull);
      expect(capturedUrl!.toString(), startsWith('$_issuer/oauth/authorize?'));

      final q = capturedUrl!.queryParameters;
      expect(q['response_type'], 'code');
      expect(q['client_id'], _clientId);
      expect(q['redirect_uri'], _redirectUri);
      expect(q['scope'], 'openid profile email offline_access');
      expect(q['code_challenge_method'], 'S256');
      expect(q['code_challenge'], isNotEmpty);
      expect(q['state'], isNotEmpty);
      expect(capturedScheme, isNotNull);
    });
  });

  group('AoidOidcAuthStrategy.initiateLogin — happy path', () {
    test(
        'fake authorize + token exchange -> Authenticated bearer session '
        '(token POST carries code_verifier, NO client_secret)', () async {
      final fake = FakeAoidEndpoint(issuer: _issuer);
      final storage = FakeTokenStorage();

      final strategy = AoidOidcAuthStrategy(
        tokenStorage: storage,
        issuer: _issuer,
        clientId: _clientId,
        redirectUri: _redirectUri,
        httpClient: fake.client,
        // Simulate AOID: echo BACK the exact state the strategy generated.
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

      expect(result, isA<Authenticated>());
      final session = (result as Authenticated).session;

      // Bearer-wiring: fixture tokens, cookieBound == false.
      expect(session.accessToken, fixtureAccessToken());
      expect(session.refreshToken, fixtureRefreshToken());
      expect(session.cookieBound, isFalse);
      expect(session.companyId, isNull);
      expect(session.role, isNull);

      // Tokens persisted via TokenStorage.
      expect(await storage.readAccessToken(), fixtureAccessToken());
      expect(await storage.readRefreshToken(), fixtureRefreshToken());

      // A single token POST fired to /oauth/token with the exchange body.
      final tokenReqs = fake.capturedRequests
          .where((r) => r.url.path.endsWith('/oauth/token'))
          .toList();
      expect(tokenReqs, hasLength(1));
      final form = Uri.splitQueryString(tokenReqs.single.body);
      expect(form['grant_type'], 'authorization_code');
      expect(form['code'], 'FAKE_CODE');
      expect(form['code_verifier'], isNotNull);
      expect(form['redirect_uri'], _redirectUri);
      expect(form['client_id'], _clientId);
      expect(form.containsKey('client_secret'), isFalse);
    });
  });

  group('AoidOidcAuthStrategy.restoreSession', () {
    test(
        'with persisted refresh token -> refresh_token grant -> rotated '
        'bearer session (persisted)', () async {
      const rotatedAccess = 'rotated-access-token-abc';
      const rotatedRefresh = 'rotated-refresh-token-xyz';

      final fake = FakeAoidEndpoint(issuer: _issuer)
        ..tokenAccessToken = rotatedAccess
        ..tokenRefreshToken = rotatedRefresh;
      final storage = FakeTokenStorage();
      await storage.writeRefreshToken(fixtureRefreshToken());

      final strategy = AoidOidcAuthStrategy(
        tokenStorage: storage,
        issuer: _issuer,
        clientId: _clientId,
        redirectUri: _redirectUri,
        httpClient: fake.client,
      );

      final session = await strategy.restoreSession();

      expect(session, isNotNull);
      expect(session!.accessToken, rotatedAccess);
      expect(session.refreshToken, rotatedRefresh);
      expect(session.cookieBound, isFalse);

      // Rotated tokens persisted.
      expect(await storage.readAccessToken(), rotatedAccess);
      expect(await storage.readRefreshToken(), rotatedRefresh);

      // A refresh_token grant (NO client_secret) was POSTed.
      final tokenReqs = fake.capturedRequests
          .where((r) => r.url.path.endsWith('/oauth/token'))
          .toList();
      expect(tokenReqs, hasLength(1));
      final form = Uri.splitQueryString(tokenReqs.single.body);
      expect(form['grant_type'], 'refresh_token');
      expect(form['refresh_token'], fixtureRefreshToken());
      expect(form['client_id'], _clientId);
      expect(form.containsKey('client_secret'), isFalse);
    });

    test('null when no refresh token persisted (no token POST)', () async {
      final fake = FakeAoidEndpoint(issuer: _issuer);
      final strategy = AoidOidcAuthStrategy(
        tokenStorage: FakeTokenStorage(),
        issuer: _issuer,
        clientId: _clientId,
        redirectUri: _redirectUri,
        httpClient: fake.client,
      );

      final session = await strategy.restoreSession();

      expect(session, isNull);
      expect(fake.capturedRequests, isEmpty);
    });
  });

  group('AoidOidcAuthStrategy.logout', () {
    test('best-effort POSTs /oauth/revoke and clears persisted tokens',
        () async {
      final fake = FakeAoidEndpoint(issuer: _issuer);
      final storage = FakeTokenStorage();
      await storage.writeAccessToken(fixtureAccessToken());
      await storage.writeRefreshToken(fixtureRefreshToken());

      final strategy = AoidOidcAuthStrategy(
        tokenStorage: storage,
        issuer: _issuer,
        clientId: _clientId,
        redirectUri: _redirectUri,
        httpClient: fake.client,
      );

      await strategy.logout();

      final revokeReqs = fake.capturedRequests
          .where((r) => r.url.path.endsWith('/oauth/revoke'))
          .toList();
      expect(revokeReqs, hasLength(1));

      // Tokens cleared.
      expect(await storage.readAccessToken(), isNull);
      expect(await storage.readRefreshToken(), isNull);
    });

    test('tolerates revoke network failure without throwing (still clears)',
        () async {
      final fake = FakeAoidEndpoint(issuer: _issuer)
        ..simulateRevokeNetworkFailure();
      final storage = FakeTokenStorage();
      await storage.writeAccessToken(fixtureAccessToken());
      await storage.writeRefreshToken(fixtureRefreshToken());

      final strategy = AoidOidcAuthStrategy(
        tokenStorage: storage,
        issuer: _issuer,
        clientId: _clientId,
        redirectUri: _redirectUri,
        httpClient: fake.client,
      );

      // Must NOT throw.
      await expectLater(strategy.logout(), completes);

      // Storage still cleared despite the revoke failure.
      expect(await storage.readAccessToken(), isNull);
      expect(await storage.readRefreshToken(), isNull);
    });
  });

  group('AoidOidcAuthStrategy — failure guards', () {
    test(
        'callback state != generated -> Failed (CSRF), NO token POST fired',
        () async {
      final fake = FakeAoidEndpoint(issuer: _issuer);
      final strategy = AoidOidcAuthStrategy(
        tokenStorage: FakeTokenStorage(),
        issuer: _issuer,
        clientId: _clientId,
        redirectUri: _redirectUri,
        httpClient: fake.client,
        // Echo a DIFFERENT state than the one the strategy generated.
        authorize: (
            {required String url, required String callbackUrlScheme}) async =>
            fakeAuthorize(
          redirectUri: _redirectUri,
          returnedState: 'attacker-supplied-state',
          code: 'FAKE_CODE',
        ),
      );

      final result = await strategy.initiateLogin({});

      expect(result, isA<Failed>());
      // CSRF guard runs BEFORE the token exchange — no /oauth/token POST.
      expect(
        fake.capturedRequests.where((r) => r.url.path.endsWith('/oauth/token')),
        isEmpty,
      );
    });

    test('token endpoint non-200 -> Failed', () async {
      final fake = FakeAoidEndpoint(issuer: _issuer)
        ..respondNextTokenCallWith(400);
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
          );
        },
      );

      final result = await strategy.initiateLogin({});
      expect(result, isA<Failed>());
    });

    test('authorize throws / user cancels -> Failed', () async {
      final fake = FakeAoidEndpoint(issuer: _issuer);
      final strategy = AoidOidcAuthStrategy(
        tokenStorage: FakeTokenStorage(),
        issuer: _issuer,
        clientId: _clientId,
        redirectUri: _redirectUri,
        httpClient: fake.client,
        authorize: (
            {required String url, required String callbackUrlScheme}) async =>
            throw Exception('user cancelled the browser flow'),
      );

      final result = await strategy.initiateLogin({});
      expect(result, isA<Failed>());
      // No token exchange attempted.
      expect(
        fake.capturedRequests.where((r) => r.url.path.endsWith('/oauth/token')),
        isEmpty,
      );
    });

    test('completeLogin(...) -> Failed(reason contains "not supported")',
        () async {
      final strategy = AoidOidcAuthStrategy(
        tokenStorage: FakeTokenStorage(),
        issuer: _issuer,
        clientId: _clientId,
        redirectUri: _redirectUri,
        httpClient: FakeAoidEndpoint(issuer: _issuer).client,
      );

      final result =
          await strategy.completeLogin('continuation-token', {'totp': '123456'});
      expect(result, isA<Failed>());
      expect((result as Failed).reason, contains('not supported'));
    });
  });
}
