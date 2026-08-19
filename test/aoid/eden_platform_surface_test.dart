// Proves lib/eden_platform.dart's exported SYMBOL SET survived the AOID
// relocation. 18 packages and ~450 import sites
// depend on that surface; the relocation must be invisible to all of them.
//
// Why this file exists instead of the diffstat check the spec specified:
//   The gate was
//       git diff --stat origin/main -- lib/eden_platform.dart
//     -> "insertions only, zero deletions"
//   which is a proxy for "no symbol removed", and a bad one in both
//   directions. Moving a file forces its `export` LINE to change path, so the
//   proxy reports a deletion while every symbol is still exported (exactly
//   this situation). Conversely you can add lines while narrowing an
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

      // --- new in this work, reachable through the same barrel ---
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

  // ── the spec, test-list items 8 and 9: THE FOLD'S CONTRACT ────────────────
  //
  // `lib/aoid.dart` and `lib/aoid_riverpod.dart` are DELETED. Everything they
  // exported now ships from `eden_platform.dart` alone. This group is what
  // makes that a contract rather than a claim: every symbol below arrives
  // through the single entrypoint imported at the top of this file, so a
  // half-applied fold is a compile error here.
  group('item 8 — the whole AOID SDK resolves from eden_platform.dart alone', () {
    test('client, config, endpoints and strategy — the four the spec names', () {
      expect(
        PkceGenerator.generate().codeVerifier.length,
        greaterThanOrEqualTo(43),
      );
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
      // NOTE — the spec asks for "one symbol from each of the seven
      // part-barrels". That was UNSATISFIABLE when written: three of the seven
      // (widgets, redirect and tenant) were deliberately
      // EMPTY placeholders whose owning TRDs had not run yet. They exported
      // nothing, so no symbol from them could be named. The next test asserts
      // the REMAINING placeholders' emptiness is by design rather than breakage.
      //
      // The widgets and redirect work have both since run and filled parts/widgets.dart and
      // parts/redirect.dart, so both are named here now and dropped from the
      // pending list below — exactly the handoff that test's failure message
      // prescribes. NOTE for whoever merges the next parallel the spec: this map is
      // ADDITIVE and the pending list is SUBTRACTIVE. Resolving a conflict here
      // by taking one side wholesale silently un-ships the other side's barrel.
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
        // Filled by the spec. The sealed forms are only useful if a consuming
        // app can actually name them from the one import, so this entry is the
        // reason the barrel export exists at all.
        'parts/widgets.dart -> widgets/aoid_login_form.dart': AoidLoginForm,
        'parts/widgets.dart -> widgets/aoid_mfa_form.dart': AoidMfaForm,
        'parts/widgets.dart -> widgets/aoid_login_theme.dart':
            const AoidLoginTheme(),
        // Filled by the spec.
        'parts/redirect.dart -> flow/aoid_redirect_options.dart':
            AoidRedirectOptions,
        'parts/redirect.dart -> flow/aoid_redirect_flow.dart': AoidRedirectFlow,
        'parts/redirect.dart -> flow/aoid_verifier_stash.dart':
            AoidVerifierStash,
      };
      expect(byPartBarrel.length, greaterThanOrEqualTo(12));
      byPartBarrel.forEach((where, symbol) {
        expect(symbol, isNotNull, reason: '$where no longer resolves');
      });
    });

    test('all seven part-barrels still exist and are exported by '
        'eden_platform.dart — the parallel-work collision guard survives the '
        'fold', () {
      // This invariant came from the DELETED test/aoid/riverpod_free_gate_test.dart.
      // It is NOT a firewall property — it is what stops TRDs running in
      // parallel from clobbering each other on one shared barrel file — so it
      // is carried forward here rather than deleted with the firewall.
      const partBarrels = <String>[
        'storage',
        'claims',
        'native',
        'modes',
        'widgets',
        'redirect',
        'tenant',
      ];
      expect(partBarrels.length, 7);

      final barrel = File('lib/eden_platform.dart').readAsStringSync();
      for (final name in partBarrels) {
        expect(
          File('lib/src/aoid/parts/$name.dart').existsSync(),
          isTrue,
          reason:
              'missing part-barrel lib/src/aoid/parts/$name.dart — a '
              'downstream the spec has nowhere to write',
        );
        expect(
          barrel,
          contains("export 'src/aoid/parts/$name.dart';"),
          reason: 'eden_platform.dart no longer exports part-barrel $name',
        );
      }
    });

    test('the remaining unfilled part-barrels are empty BY DESIGN, each naming '
        'its owning the spec — and as of the spec there are none left', () {
      // Without this, "tenant.dart exports nothing" is indistinguishable from
      // "someone deleted its exports". Each placeholder must say whose it is.
      //
      // The widgets, redirect and tenant work each ran in its own worktree off
      // origin/main and each removed ITS OWN key from this map. The three
      // removals compose to an EMPTY map. Resolving that merge by taking any
      // one branch wholesale would have restored another branch's key and
      // silently un-shipped a barrel that had in fact landed — so all three
      // removals are kept here deliberately.
      const pending = <String, String>{};
      pending.forEach((name, owner) {
        final src = File('lib/src/aoid/parts/$name.dart').readAsStringSync();
        expect(
          RegExp(r"^\s*export\s+'", multiLine: true).hasMatch(src),
          isFalse,
          reason:
              'parts/$name.dart now has exports — update the test above to '
              'name one of its symbols, and drop it from this list',
        );
        expect(
          src,
          contains(owner),
          reason: 'parts/\$name.dart must name its owning area (\$owner)',
        );
      });

      // An empty `pending` makes the loop above vacuous, which would read as a
      // green while proving nothing. The complement is what carries the weight
      // now: if nothing is pending then EVERY barrel must actually export
      // something. This is what would fail if a merge resolution dropped one of
      // the three branches' work while still emptying the pending list.
      const allBarrels = <String>[
        'storage',
        'claims',
        'native',
        'modes',
        'widgets',
        'redirect',
        'tenant',
      ];
      for (final name in allBarrels) {
        if (pending.containsKey(name)) continue;
        final src = File('lib/src/aoid/parts/$name.dart').readAsStringSync();
        expect(
          RegExp(r"^\s*export\s+'", multiLine: true).hasMatch(src),
          isTrue,
          reason:
              'parts/$name.dart is not in the pending list yet exports '
              'nothing — either its owning the spec was un-shipped by a bad merge '
              'resolution, or it belongs back in `pending`',
        );
      }
    });
  });

  group('item 9 — the fold is complete, not half-applied', () {
    test('neither lib/aoid.dart nor lib/aoid_riverpod.dart exists', () {
      expect(
        File('lib/aoid.dart').existsSync(),
        isFalse,
        reason: 'lib/aoid.dart was folded into eden_platform.dart by the spec',
      );
      expect(
        File('lib/aoid_riverpod.dart').existsSync(),
        isFalse,
        reason: 'lib/aoid_riverpod.dart was folded in by the spec',
      );
      //...and the firewall gate that guarded the split went with it. It
      // asserted that the AOID surface never resolves a riverpod symbol —
      // precisely the property the design notes rejected — so it was DELETED
      // rather than weakened. A softened version would have kept the firewall's
      // premise alive in the suite after the code abandoned it.
      expect(
        File('test/aoid/riverpod_free_gate_test.dart').existsSync(),
        isFalse,
        reason: 'the riverpod firewall gate asserts what D2 rejected',
      );
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
      expect(
        scanned,
        greaterThan(100),
        reason:
            'only $scanned files scanned — the walk is broken, so the '
            'emptiness assertion below would prove nothing',
      );
      expect(
        offenders,
        isEmpty,
        reason: 'these still import a deleted barrel: $offenders',
      );
    });

    test('POSITIVE CONTROL: that scan really does detect a dangling import', () {
      // The test above is an "assert nothing matches" check. Prove the pattern
      // bites before trusting the absence.
      final re = RegExp(
        r"^\s*(?:import|export)\s+'package:eden_platform_flutter/"
        r"aoid(?:_riverpod)?\.dart'",
        multiLine: true,
      );
      expect(
        re.hasMatch("import 'package:eden_platform_flutter/aoid.dart';"),
        isTrue,
      );
      expect(
        re.hasMatch(
          "import 'package:eden_platform_flutter/aoid_riverpod.dart';",
        ),
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
        re.hasMatch(
          "import 'package:eden_platform_flutter/eden_platform.dart';",
        ),
        isFalse,
      );
    });
  });
}
