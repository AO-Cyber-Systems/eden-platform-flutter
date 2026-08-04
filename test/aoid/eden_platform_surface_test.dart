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

import 'dart:io';

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

  // ── TRD 50-24, test-list items 8 and 9: THE FOLD'S CONTRACT ────────────────
  //
  // `lib/aoid.dart` and `lib/aoid_riverpod.dart` are DELETED. Everything they
  // exported now ships from `eden_platform.dart` alone. This group is what
  // makes that a contract rather than a claim: every symbol below arrives
  // through the single entrypoint imported at the top of this file, so a
  // half-applied fold is a compile error here.
  group('item 8 — the whole AOID SDK resolves from eden_platform.dart alone',
      () {
    test('client, config, endpoints and strategy — the four the TRD names', () {
      expect(PkceGenerator.generate().codeVerifier.length,
          greaterThanOrEqualTo(43));
      expect(PkcePair, isNotNull);
      expect(AoidConfig, isNotNull);
      expect(AoidEndpoints.parse('https://x.example').issuer.host, 'x.example');
      expect(AoidOidcAuthStrategy, isNotNull);
      // The riverpod-facing half, formerly behind aoid_riverpod.dart. Its
      // presence here is the half of the fold most likely to be forgotten,
      // because the two barrels were deleted in one step but came from
      // different files.
      expect(aoidConfigProvider, isNotNull);
      expect(buildAoidStrategy, isNotNull);
      expect(buildAoidOverrides, isNotNull);
    });

    test('one symbol from each POPULATED part-barrel', () {
      // NOTE — the TRD asks for "one symbol from each of the seven
      // part-barrels". That is UNSATISFIABLE as written: three of the seven
      // (redirect -> 50-12, tenant -> 50-13, widgets -> 50-11) are deliberately
      // EMPTY placeholders whose owning TRDs have not run yet. They export
      // nothing, so no symbol from them can be named. The next test asserts
      // their emptiness is by design rather than breakage.
      final byPartBarrel = <String, Object?>{
        'parts/claims.dart  -> claims/aoid_claims.dart': AoidAccessClaims,
        'parts/claims.dart  -> claims/tenant_ref.dart': AoidIdClaims,
        'parts/modes.dart   -> mode/aoid_deployment_mode.dart':
            AoidDeploymentMode.bff,
        'parts/modes.dart   -> mode/aoid_code_sink.dart': AoidModeWiring,
        'parts/storage.dart -> storage/aoid_token_store.dart': AoidTokenStore,
        'parts/storage.dart -> aoid_session.dart': AoidSession,
        'parts/native.dart  -> transport/aoid_native_client.dart':
            AoidNativeClient,
        'parts/native.dart  -> transport/aoid_error.dart': AoidError,
        'parts/native.dart  -> flow/aoid_native_flow.dart': AoidNativeFlow,
      };
      expect(byPartBarrel.length, greaterThanOrEqualTo(9));
      byPartBarrel.forEach((where, symbol) {
        expect(symbol, isNotNull, reason: '$where no longer resolves');
      });
    });

    test('all seven part-barrels still exist and are exported by '
        'eden_platform.dart — the parallel-TRD collision guard survives the '
        'fold', () {
      // This invariant came from the DELETED test/aoid/riverpod_free_gate_test.dart.
      // It is NOT a firewall property — it is what stops TRDs running in
      // parallel from clobbering each other on one shared barrel file — so it
      // is carried forward here rather than deleted with the firewall.
      const partBarrels = <String>[
        'storage', 'claims', 'native', 'modes', 'widgets', 'redirect', 'tenant',
      ];
      expect(partBarrels.length, 7);

      final barrel = File('lib/eden_platform.dart').readAsStringSync();
      for (final name in partBarrels) {
        expect(
          File('lib/src/aoid/parts/$name.dart').existsSync(),
          isTrue,
          reason: 'missing part-barrel lib/src/aoid/parts/$name.dart — a '
              'downstream TRD has nowhere to write',
        );
        expect(
          barrel,
          contains("export 'src/aoid/parts/$name.dart';"),
          reason: 'eden_platform.dart no longer exports part-barrel $name',
        );
      }
    });

    test('the three unfilled part-barrels are empty BY DESIGN, each naming its '
        'owning TRD', () {
      // Without this, "redirect.dart exports nothing" is indistinguishable from
      // "someone deleted its exports". Each placeholder must say whose it is.
      // 'tenant' left this list when TRD 50-13 filled parts/tenant.dart. Its
      // surface is pinned by test/aoid/tenant/*, through this same barrel,
      // rather than by another entry above — deliberately, to keep this
      // shared file's diff to ONE line while 50-11 and 50-12 run concurrently.
      const pending = {'redirect': '50-12', 'widgets': '50-11'};
      pending.forEach((name, trd) {
        final src = File('lib/src/aoid/parts/$name.dart').readAsStringSync();
        expect(
          RegExp(r"^\s*export\s+'", multiLine: true).hasMatch(src),
          isFalse,
          reason: 'parts/$name.dart now has exports — update the test above to '
              'name one of its symbols, and drop it from this list',
        );
        expect(src, contains(trd),
            reason: 'parts/$name.dart must name its owning TRD ($trd)');
      });
    });
  });

  group('item 9 — the fold is complete, not half-applied', () {
    test('neither lib/aoid.dart nor lib/aoid_riverpod.dart exists', () {
      expect(File('lib/aoid.dart').existsSync(), isFalse,
          reason: 'lib/aoid.dart was folded into eden_platform.dart by 50-24');
      expect(File('lib/aoid_riverpod.dart').existsSync(), isFalse,
          reason: 'lib/aoid_riverpod.dart was folded in by 50-24');
      // ...and the firewall gate that guarded the split went with it. It
      // asserted that the AOID surface never resolves a riverpod symbol —
      // precisely the property 50-CONTEXT.md D2 rejected — so it was DELETED
      // rather than weakened. A softened version would have kept the firewall's
      // premise alive in the suite after the code abandoned it.
      expect(File('test/aoid/riverpod_free_gate_test.dart').existsSync(), isFalse,
          reason: 'the riverpod firewall gate asserts what D2 rejected');
    });

    test('nothing anywhere in the repository still imports either barrel', () {
      // Scans EVERY file, not just *.dart: the conflation compile-gate probe
      // lives in `fixtures/conflation_probe.dart.txt` and is compiled by the
      // analyzer at runtime, so a *.dart-only sweep would have missed a real
      // dangling import.
      final offenders = <String>[];
      var scanned = 0;
      for (final dir in ['lib', 'test', 'example', 'doc', 'tool']) {
        final d = Directory(dir);
        if (!d.existsSync()) continue;
        for (final f in d.listSync(recursive: true).whereType<File>()) {
          if (f.path.contains('/.')) continue;
          final String src;
          try {
            src = f.readAsStringSync();
          } on FormatException {
            continue; // binary
          }
          scanned++;
          final re = RegExp(
            r"^\s*(?:import|export)\s+'package:eden_platform_flutter/"
            r"aoid(?:_riverpod)?\.dart'",
            multiLine: true,
          );
          for (final _ in re.allMatches(src)) {
            offenders.add(f.path);
          }
        }
      }
      // Non-vacuity: a broken walk that scanned nothing would pass silently.
      expect(scanned, greaterThan(100),
          reason: 'only $scanned files scanned — the walk is broken, so the '
              'emptiness assertion below would prove nothing');
      expect(offenders, isEmpty,
          reason: 'these still import a deleted barrel: $offenders');
    });

    test('POSITIVE CONTROL: that scan really does detect a dangling import', () {
      // The test above is an "assert nothing matches" check. Prove the pattern
      // bites before trusting the absence.
      final re = RegExp(
        r"^\s*(?:import|export)\s+'package:eden_platform_flutter/"
        r"aoid(?:_riverpod)?\.dart'",
        multiLine: true,
      );
      expect(re.hasMatch("import 'package:eden_platform_flutter/aoid.dart';"),
          isTrue);
      expect(
        re.hasMatch("import 'package:eden_platform_flutter/aoid_riverpod.dart';"),
        isTrue,
      );
      expect(
        re.hasMatch("export 'package:eden_platform_flutter/aoid.dart';"),
        isTrue,
      );
      // Prose naming the old barrel is history, not a dangling import, and must
      // NOT trip the scan — several lib/ headers deliberately record why the
      // split existed.
      expect(
        re.hasMatch('// formerly package:eden_platform_flutter/aoid.dart'),
        isFalse,
      );
      // The surviving entrypoint must not be caught by the pattern.
      expect(
        re.hasMatch("import 'package:eden_platform_flutter/eden_platform.dart';"),
        isFalse,
      );
    });
  });
}
