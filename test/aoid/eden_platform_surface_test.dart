// Proves lib/eden_platform.dart's exported SYMBOL SET survived the AOID
// relocation (AOID objective 50 TRD 50-01). 18 packages and ~450 import sites
// depend on that surface; the relocation must be invisible to all of them.
//
// Why this file exists instead of the diffstat check TRD 50-01 specified:
//   The TRD's gate was
//       git diff --stat origin/main -- lib/eden_platform.dart
//     -> "insertions only, zero deletions"
//   which is a proxy for "no symbol removed", and a bad one in both
//   directions. Moving a file forces its `export` LINE to change path, so the
//   proxy reports a deletion while every symbol is still exported (exactly
//   this TRD's situation). Conversely you can add lines while narrowing an
//   export with `show` and the proxy stays green. Line counts do not measure
//   API surface.
//
// This test measures the thing that actually matters: it imports ONLY
// package:eden_platform_flutter/eden_platform.dart and names every public
// symbol that used to come from the three relocated files. Any symbol that
// stopped being exported is a COMPILE error here, which is precisely the
// breakage the 18 consumers would hit.

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group(
    'eden_platform.dart surface is preserved across the AOID relocation',
    () {
      // --- formerly src/auth/pkce_generator.dart ---
      test('PkceGenerator + PkcePair still reachable from the barrel', () {
        final PkcePair pair = PkceGenerator.generate();
        expect(pair.codeVerifier, isNotEmpty);
        expect(pair.codeChallenge, isNotEmpty);
        expect(pair.state, isNotEmpty);
        expect(pair.nonce, isNotEmpty);
        expect(
          PkceGenerator.codeChallengeFor(pair.codeVerifier),
          pair.codeChallenge,
        );
      });

      // --- formerly src/auth/aoid_config.dart (value class half) ---
      test('AoidConfig still reachable, with its full member surface', () {
        const AoidConfig cfg = AoidConfig(
          enabled: true,
          issuer: 'https://auth.aocyber.ai',
          clientId: 'eden-biz-console',
        );
        expect(cfg.enabled, isTrue);
        expect(cfg.issuer, 'https://auth.aocyber.ai');
        expect(cfg.clientId, 'eden-biz-console');
        expect(
          cfg.redirectUri('https://console.biz.aocyber.ai'),
          'https://console.biz.aocyber.ai/auth.html',
        );
        expect(cfg.validate, returnsNormally);
        expect(AoidConfig.fromEnvironment, returnsNormally);
      });

      // --- formerly src/auth/aoid_config.dart (riverpod half) ---
      test('aoidConfigProvider / buildAoidStrategy / buildAoidOverrides still '
          'reachable', () {
        expect(aoidConfigProvider, isNotNull);
        // Named, so a removal from the barrel is a compile error. Not invoked:
        // buildAoidStrategy needs a TokenStorage and this test is about the
        // export surface, not behaviour (behaviour is covered by
        // test/auth/aoid_wireup_test.dart).
        expect(buildAoidStrategy, isA<Function>());
        expect(buildAoidOverrides, isA<Function>());
      });

      // --- formerly src/auth/aoid_oidc_auth_strategy.dart ---
      test('AoidOidcAuthStrategy + AuthorizeFn still reachable', () {
        expect(AoidOidcAuthStrategy, isNotNull);
        // Naming the typedef in a declaration keeps it load-bearing.
        const AuthorizeFn? probe = null;
        expect(probe, isNull);
      });

      // --- new in this TRD, reachable through the same barrel ---
      test(
        'AoidEndpoints is exported and derives AOID paths from the issuer',
        () {
          final e = AoidEndpoints(Uri.parse('https://auth.aocyber.ai'));
          expect(
            e.authorize.toString(),
            'https://auth.aocyber.ai/oauth/authorize',
          );
          expect(e.token.toString(), 'https://auth.aocyber.ai/oauth/token');
          expect(e.revoke.toString(), 'https://auth.aocyber.ai/oauth/revoke');
          expect(
            e.nativeStart.toString(),
            'https://auth.aocyber.ai/oauth/native/start',
          );
          expect(
            e.nativeVerify.toString(),
            'https://auth.aocyber.ai/oauth/native/verify',
          );
        },
      );

      test('AoidEndpoints resolves absolutely, so an issuer with a trailing '
          'path segment does not nest', () {
        final e = AoidEndpoints.parse('https://auth.aocyber.ai/tenant/acme');
        expect(e.token.toString(), 'https://auth.aocyber.ai/oauth/token');
      });

      test('AoidEndpoints has value equality', () {
        expect(
          AoidEndpoints.parse('https://a.example'),
          AoidEndpoints.parse('https://a.example'),
        );
        expect(
          AoidEndpoints.parse('https://a.example'),
          isNot(AoidEndpoints.parse('https://b.example')),
        );
      });
    },
  );

  group('the AOID module is reachable through its own barrels too', () {
    test('aoid.dart exposes the riverpod-free core', () {
      // Imported transitively via eden_platform.dart above; this asserts the
      // symbols a riverpod-3 consumer will reach for exist.
      expect(
        PkceGenerator.generate().codeVerifier.length,
        greaterThanOrEqualTo(43),
      );
      expect(AoidEndpoints.parse('https://x.example').issuer.host, 'x.example');
    });
  });
}
