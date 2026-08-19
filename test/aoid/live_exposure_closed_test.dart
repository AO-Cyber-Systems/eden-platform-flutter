// The C3 exposure, closed at the two places it actually lives.
//
// the design notes premise correction C3 composes three verified facts into one
// live production exposure:
//   1. SecureTokenStorage._writeOrDelete downgraded ANY secure-storage failure
//      to shared_preferences — localStorage on web (covered by
//      test/secure_token_storage_test.dart, not this file);
//   2. AoidOidcAuthStrategy wrote the refresh token through it
//      UNCONDITIONALLY;
//   3. AoidConfig.fromEnvironment() defaulted enabled:true against
//      issuer https://auth.aocyber.ai, clientId eden-biz-console — a WEB
//      console, in PRODUCTION, ON BY DEFAULT.
//
// This file gates (2) and (3). Task 1's structural work
// (test/aoid/storage/*) makes the NEW module incapable of the forbidden state;
// this file stops the ALREADY-SHIPPING path, which is where the exposure
// actually was.
//
// WHAT THIS FILE DOES NOT PROVE: `kIsWeb` is a compile-time constant and
// `flutter test` is never web. Coverage of the web branch comes from the
// injected `isWeb` seam (default `kIsWeb`), the same pattern
// lib/src/networking/connect_cookie_interceptor.dart:55-67 already ships.
//
// ignore_for_file: avoid_relative_lib_imports

import 'package:eden_platform_flutter/src/aoid/aoid_config.dart';
import 'package:eden_platform_flutter/src/aoid_riverpod/aoid_oidc_auth_strategy.dart';
import 'package:eden_platform_flutter/src/auth/auth_strategy.dart';
import 'package:eden_platform_flutter/src/auth/token_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../auth/fixtures/aoid_fixtures.dart';
import '../auth/fixtures/fake_aoid_endpoint.dart';

const _issuer = 'https://auth.aocyber.ai';
const _clientId = 'eden-biz-console';
const _redirectUri = 'https://console.biz.aocyber.ai/auth.html';

/// Map-backed [TokenStorage] that logs every call.
///
/// The log is the point: asserting on the returned session tells you what the
/// CALLER sees, and the exposure is about what an ATTACKER can read. These
/// tests assert on what was written.
class RecordingTokenStorage implements TokenStorage {
  final Map<String, String> _values = <String, String>{};
  final List<String> calls = <String>[];

  /// Every refresh-token write that carried an actual value. If this is
  /// non-empty on a web run, the exposure is open.
  List<String> get persistedRefreshValues => calls
      .where(
        (c) =>
            c.startsWith('writeRefreshToken(') &&
            c != 'writeRefreshToken(null)',
      )
      .toList();

  @override
  Future<String?> readAccessToken() async {
    calls.add('readAccessToken');
    return _values['access'];
  }

  @override
  Future<String?> readRefreshToken() async {
    calls.add('readRefreshToken');
    return _values['refresh'];
  }

  @override
  Future<void> writeAccessToken(String? value) async {
    calls.add('writeAccessToken($value)');
    if (value == null) {
      _values.remove('access');
    } else {
      _values['access'] = value;
    }
  }

  @override
  Future<void> writeRefreshToken(String? value) async {
    calls.add('writeRefreshToken($value)');
    if (value == null) {
      _values.remove('refresh');
    } else {
      _values['refresh'] = value;
    }
  }

  @override
  Future<void> clear() async {
    calls.add('clear');
    _values.clear();
  }

  /// Seeds a value WITHOUT logging a call — for "a legacy token is already
  /// sitting in storage" setups.
  void seedRefresh(String value) => _values['refresh'] = value;
}

AoidOidcAuthStrategy _strategyFor({
  required TokenStorage storage,
  required FakeAoidEndpoint fake,
  required bool isWeb,
}) => AoidOidcAuthStrategy(
  tokenStorage: storage,
  issuer: _issuer,
  clientId: _clientId,
  redirectUri: _redirectUri,
  httpClient: fake.client,
  isWeb: isWeb,
  // Simulate AOID: echo back the exact CSRF state the strategy generated.
  authorize: ({required String url, required String callbackUrlScheme}) async {
    final generatedState = Uri.parse(url).queryParameters['state']!;
    return fakeAuthorize(
      redirectUri: _redirectUri,
      returnedState: generatedState,
      code: 'FAKE_CODE',
    );
  },
);

void main() {
  // ==========================================================================
  // POSITIVE CONTROLS — Mode B on native must KEEP WORKING.
  //
  // D4 wants the refresh token in the device keychain on native. Fixing web by
  // breaking native would be a regression dressed as a security fix, and every
  // "is null on web" assertion below would pass against a strategy that simply
  // never persists anything.
  // ==========================================================================
  group('POSITIVE CONTROLS — native (Mode B) still persists', () {
    test('initiateLogin on NATIVE persists the refresh token, as D4 Mode B '
        'requires', () async {
      final fake = FakeAoidEndpoint(issuer: _issuer);
      final storage = RecordingTokenStorage();
      final strategy = _strategyFor(storage: storage, fake: fake, isWeb: false);

      final result = await strategy.initiateLogin(<String, String>{});

      expect(result, isA<Authenticated>());
      expect(await storage.readRefreshToken(), fixtureRefreshToken());
      expect(
        storage.persistedRefreshValues,
        ['writeRefreshToken(${fixtureRefreshToken()})'],
        reason:
            'if this is empty, native Mode B is broken and every web '
            'assertion in this file is vacuous',
      );
      expect(
        (result as Authenticated).session.refreshToken,
        fixtureRefreshToken(),
      );
    });

    test(
      'restoreSession on NATIVE persists the ROTATED refresh token',
      () async {
        const rotatedRefresh = 'rotated-refresh-token-native-control';
        final fake = FakeAoidEndpoint(issuer: _issuer)
          ..tokenRefreshToken = rotatedRefresh;
        final storage = RecordingTokenStorage()
          ..seedRefresh('seeded-refresh-token-native-control');

        final session = await _strategyFor(
          storage: storage,
          fake: fake,
          isWeb: false,
        ).restoreSession();

        expect(session, isNotNull);
        expect(await storage.readRefreshToken(), rotatedRefresh);
      },
    );
  });

  // ==========================================================================
  // (b) AoidOidcAuthStrategy — the unconditional write, on web.
  // ==========================================================================
  group('D4/SDK-11 — the AOID strategy never persists a refresh token on web', () {
    test('initiateLogin on WEB writes NO refresh token to storage', () async {
      final fake = FakeAoidEndpoint(issuer: _issuer);
      final storage = RecordingTokenStorage();

      final result = await _strategyFor(
        storage: storage,
        fake: fake,
        isWeb: true,
      ).initiateLogin(<String, String>{});

      // Login still SUCCEEDS — this is not "break web to secure it".
      expect(result, isA<Authenticated>());
      expect(
        (result as Authenticated).session.accessToken,
        fixtureAccessToken(),
      );

      // THE ASSERTION THAT MATTERS: what an attacker could read.
      expect(
        storage.persistedRefreshValues,
        isEmpty,
        reason:
            'a refresh token reaching any web store is the configuration D4 '
            'forbids and C3 records as shipping. Calls: ${storage.calls}',
      );
      expect(await storage.readRefreshToken(), isNull);
    });

    test('the WEB session itself carries no refresh token — so AuthNotifier'
        '._persistTokens cannot leak it downstream', () async {
      // AuthNotifier._persistTokens (auth_provider.dart) does
      // `_tokenStorage.writeRefreshToken(session.refreshToken)` for every
      // non-cookie-bound session. If the session carried the real token, the
      // strategy's own restraint would be undone one layer up.
      final fake = FakeAoidEndpoint(issuer: _issuer);
      final result = await _strategyFor(
        storage: RecordingTokenStorage(),
        fake: fake,
        isWeb: true,
      ).initiateLogin(<String, String>{});

      final session = (result as Authenticated).session;
      expect(session.refreshToken, isEmpty);
      expect(session.refreshToken, isNot(fixtureRefreshToken()));
      expect(session.accessToken, isNotEmpty);
    });

    test(
      'a login on WEB CLEARS a legacy refresh token already in storage',
      () async {
        // Escalation item 1 (tokens already in real users' localStorage) is not
        // closed by this work, but a web login must at least not leave the stale
        // one behind.
        final fake = FakeAoidEndpoint(issuer: _issuer);
        final storage = RecordingTokenStorage()
          ..seedRefresh('legacy-refresh-token-from-the-exposed-build');

        await _strategyFor(
          storage: storage,
          fake: fake,
          isWeb: true,
        ).initiateLogin(<String, String>{});

        expect(await storage.readRefreshToken(), isNull);
        expect(storage.calls, contains('writeRefreshToken(null)'));
      },
    );

    test(
      'restoreSession on WEB does not persist the rotated refresh token',
      () async {
        const rotatedRefresh = 'rotated-refresh-token-web-case';
        final fake = FakeAoidEndpoint(issuer: _issuer)
          ..tokenRefreshToken = rotatedRefresh;
        final storage = RecordingTokenStorage()
          ..seedRefresh('legacy-refresh-token-web-case');

        final session = await _strategyFor(
          storage: storage,
          fake: fake,
          isWeb: true,
        ).restoreSession();

        // The exchange itself is allowed — a legacy token that already exists is
        // worth trading for a session. Re-persisting the rotated one is not.
        expect(session, isNotNull);
        expect(session!.accessToken, isNotEmpty);
        expect(storage.persistedRefreshValues, isEmpty);
        expect(await storage.readRefreshToken(), isNull);
      },
    );

    test('logout on WEB still clears storage', () async {
      final fake = FakeAoidEndpoint(issuer: _issuer);
      final storage = RecordingTokenStorage()
        ..seedRefresh('refresh-token-web-logout-case');

      await _strategyFor(storage: storage, fake: fake, isWeb: true).logout();

      expect(await storage.readRefreshToken(), isNull);
      expect(storage.calls, contains('clear'));
    });
  });

  // ==========================================================================
  // (c) AoidConfig.fromEnvironment() — the default that made C3 live.
  // ==========================================================================
  group('D4/SDK-11 — AOID login no longer defaults ON against production', () {
    test('enabled defaults to FALSE with no --dart-define', () {
      // The polarity IS the fix. Defaulting on, against a web console, in
      // production, is what turned a latent flaw into a live exposure.
      expect(
        AoidConfig.fromEnvironment().enabled,
        isFalse,
        reason:
            'AOID console login must be opt-in per build via '
            '--dart-define=AOID_CONSOLE_LOGIN_ENABLED=true',
      );
    });

    test('issuer and clientId defaults are PRESERVED, so opting in needs no '
        'extra defines', () {
      final cfg = AoidConfig.fromEnvironment();
      expect(cfg.issuer, 'https://auth.aocyber.ai');
      expect(cfg.clientId, 'eden-biz-console');
    });

    test('the default config validates as a no-op (flag-off is zero behaviour '
        'change)', () {
      expect(AoidConfig.fromEnvironment().validate, returnsNormally);
    });

    // POSITIVE CONTROL: the value class is not inert. Without this, the three
    // assertions above would pass against a class whose every field was
    // hardcoded.
    test('POSITIVE CONTROL: an explicitly enabled config still validates and '
        'still fails fast on an empty issuer', () {
      const enabled = AoidConfig(
        enabled: true,
        issuer: _issuer,
        clientId: _clientId,
      );
      expect(enabled.enabled, isTrue);
      expect(enabled.validate, returnsNormally);

      const broken = AoidConfig(enabled: true, issuer: '', clientId: _clientId);
      expect(broken.validate, throwsA(isA<StateError>()));
    });
  });
}
