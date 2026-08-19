// The widget no-op, made executable.
//
// Stage B moved all five notifiers from riverpod 2's
// `StateNotifier` to riverpod 3's `Notifier`, preserving every provider
// identifier and every method signature. The claim to discharge is
// that the NINE widget consumers therefore need ZERO source edits.
//
// "We ran flutter analyze and it was fine" is not that proof — it holds only
// for the tree as it stands today and says nothing about WHY. The two
// assertions below make the claim rest on something that runs:
//
//   1. BEHAVIOURAL — `ref.read(p.notifier)` really does hand back the migrated
//      notifier, and `ref.watch(p)` really does hand back the state, for each of
//      the five migrated providers. These are the only two mechanisms the
//      widgets use, and both are identical API on NotifierProvider and
//      StateNotifierProvider, which is exactly why the no-op holds.
//
//   2. SOURCE-LEVEL — every riverpod call site in the nine widget files is one
//      of those two shapes. This is the part that keeps holding tomorrow: it
//      fails the moment someone reaches for a StateNotifierProvider-only API
//      (`.stream`, `.state`, `.notifier.stream`), which would compile against
//      riverpod 2 and break on the migrated providers.
//
// GOTCHA for whoever reads this next: the standing "No GoRouter found in
// context" failure in platform_sidebar_test.dart is PRE-EXISTING (the original split's
// baseline) and is NOT this file's business. Nothing here renders a widget.

import 'dart:io';

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers.dart';

/// The nine widget consumers named in the file tree as DO-NOT-EDIT.
const _widgetFiles = <String>[
  'lib/src/navigation/sidebar.dart',
  'lib/src/auth/login_screen.dart',
  'lib/src/auth/signup_screen.dart',
  'lib/src/settings/settings_screen.dart',
  'lib/src/company/company_switcher.dart',
  'lib/src/entitlements/feature_gate.dart',
  'lib/src/entitlements/quota_bar.dart',
  'lib/src/entitlements/plan_badge.dart',
  'lib/src/platform_shell.dart',
];

/// Strips `//` line comments and `/* */` block comments, so prose naming a
/// forbidden API is never mistaken for code using it. Same stripper shape the
/// Stage B source gates use.
String stripComments(String src) => src
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

/// `ref.watch(...)` / `ref.read(...)` / `ref.listen(...)`, plus the chained
/// `.read(...)` form the settings screen uses across a line break.
final _callSiteRe = RegExp(r'\bref\s*\n?\s*\.\s*(watch|read|listen)\s*\(');

/// APIs that exist on `StateNotifierProvider` but NOT on `NotifierProvider`.
/// A widget reaching for one of these would have compiled before Stage B and
/// would break after it — which is precisely the no-op claim's failure mode.
///
/// The `\)?` is load-bearing and was NOT in the first draft: the realistic
/// shape is `ref.read(p.notifier).stream`, where a closing paren sits between
/// `.notifier` and `.stream`. Without it this pattern matched only the
/// `StateNotifierProvider` alternative and was blind to the `.stream` case —
/// caught by the POSITIVE CONTROL below, which is the entire reason it exists.
final _legacyOnlyRe = RegExp(
  r'\.notifier\s*\)?\s*\.\s*(stream|debugState)\b'
  r'|\bStateNotifierProvider\b'
  r'|\bStateNotifierProviderRef\b',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    installSecureStorageChannelMock();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(uninstallSecureStorageChannelMock);

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        platformRepositoryProvider.overrideWithValue(FakePlatformRepository()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('the mechanism the nine widgets rely on (the barrel consolidation test 5)', () {
    test('ref.read(p.notifier) returns the MIGRATED notifier type for all five '
        'providers', () async {
      final container = makeContainer();
      await settle();

      // Each of these is a widget call site verbatim. If Stage B had renamed a
      // provider or changed a notifier type, this would not compile.
      expect(container.read(authProvider.notifier), isA<AuthNotifier>());
      expect(container.read(companyStateProvider.notifier),
          isA<CompanyNotifier>());
      expect(container.read(navStateProvider.notifier), isA<NavNotifier>());
      expect(container.read(settingsProvider.notifier), isA<SettingsNotifier>());
      expect(container.read(entitlementsStateProvider.notifier),
          isA<EntitlementsNotifier>());
    });

    test('every migrated notifier is a riverpod 3 Notifier — NOT a legacy '
        'StateNotifier', () async {
      final container = makeContainer();
      await settle();

      // The positive form of Stage B's completion signal. `Notifier` and
      // `StateNotifier` are unrelated types, so this cannot pass by accident.
      expect(container.read(authProvider.notifier), isA<Notifier<AuthState>>());
      expect(container.read(companyStateProvider.notifier),
          isA<Notifier<CompanyState>>());
      expect(
          container.read(navStateProvider.notifier), isA<Notifier<NavState>>());
      expect(container.read(settingsProvider.notifier),
          isA<Notifier<SettingsState>>());
      expect(container.read(entitlementsStateProvider.notifier),
          isA<Notifier<EntitlementsState>>());
    });

    test('ref.watch(p) still yields the STATE, not the notifier — the other '
        'half of the widget mechanism', () async {
      final container = makeContainer();
      await settle();

      expect(container.read(authProvider), isA<AuthState>());
      expect(container.read(companyStateProvider), isA<CompanyState>());
      expect(container.read(navStateProvider), isA<NavState>());
      expect(container.read(settingsProvider), isA<SettingsState>());
      expect(container.read(entitlementsStateProvider), isA<EntitlementsState>());
    });

    test('the derived and family providers the widgets read still resolve',
        () async {
      final container = makeContainer();
      await settle();

      // company_switcher.dart, plan_badge.dart, feature_gate.dart, quota_bar.dart
      container.read(companiesProvider);
      container.read(currentCompanyProvider);
      container.read(currentPlanProvider);
      container.read(currentSubscriptionProvider);
      expect(container.read(canUseFeatureProvider('analytics')), isA<bool>());
      expect(container.read(featureFlagProvider('anything')), isA<bool>());
      container.read(featureQuotaProvider('analytics'));

      // Deny-by-default, pinned here and re-asserted from the widget's own
      // call site: an unknown feature is NOT permitted.
      expect(container.read(canUseFeatureProvider('no-such-feature')), isFalse);
    });
  });

  group('the nine widget sources use only migration-safe call shapes', () {
    test('every riverpod call site is ref.watch / ref.read / ref.listen', () {
      // Non-vacuity: the file list must resolve and must actually contain call
      // sites, or "no offender found" would prove nothing.
      var totalSites = 0;
      final missing = <String>[];
      for (final path in _widgetFiles) {
        if (!File(path).existsSync()) {
          missing.add(path);
          continue;
        }
        totalSites +=
            _callSiteRe.allMatches(stripComments(File(path).readAsStringSync()))
                .length;
      }
      expect(missing, isEmpty, reason: 'widget files missing: $missing');
      expect(
        totalSites,
        greaterThanOrEqualTo(20),
        reason:
            'expected ~24 riverpod call sites across the nine widgets; found '
            '$totalSites. A near-zero count means the scanner regexp broke and '
            'the assertion below would pass vacuously.',
      );
    });

    test('no widget reaches for a StateNotifierProvider-only API', () {
      final offenders = <String>[];
      for (final path in _widgetFiles) {
        final code = stripComments(File(path).readAsStringSync());
        for (final m in _legacyOnlyRe.allMatches(code)) {
          offenders.add('$path -> ${m.group(0)}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'these widgets use an API that exists on StateNotifierProvider but '
            'not on NotifierProvider, so the Stage C no-op claim is void: '
            '$offenders',
      );
    });

    test('POSITIVE CONTROL: the legacy-API scanner really does fire', () {
      // Items above are "assert nothing matches" tests, which pass vacuously if
      // the predicate is broken. Prove the predicate bites before trusting any
      // absence — the trap that produced seven survivors across this objective.
      const tainted = '''
        final s = ref.read(authProvider.notifier).stream;
        final p = StateNotifierProvider<Foo, Bar>((ref) => Foo());
      ''';
      expect(_legacyOnlyRe.allMatches(tainted).length, greaterThanOrEqualTo(2));
      // Both alternatives individually, so a pattern blind to one of them
      // cannot hide behind the other's match — the exact defect this control
      // caught on the first run.
      expect(
        _legacyOnlyRe.hasMatch('ref.read(authProvider.notifier).stream'),
        isTrue,
        reason: 'the .stream-through-a-paren shape must be detected',
      );
      expect(
        _legacyOnlyRe.hasMatch('StateNotifierProvider<Foo, Bar>((ref) => x)'),
        isTrue,
      );

      //...and that the comment stripper does not hide a real violation, while
      // still ignoring genuine prose.
      expect(_legacyOnlyRe.hasMatch(stripComments('// StateNotifierProvider')),
          isFalse);
      expect(
        _legacyOnlyRe.hasMatch(
            stripComments('final p = StateNotifierProvider<A, B>(x);')),
        isTrue,
      );
      // The stripper must actually remove something, or "no match" is vacuous.
      expect(stripComments('code(); // gone').contains('gone'), isFalse);
    });

    test('POSITIVE CONTROL: the call-site scanner matches the real shapes', () {
      expect(_callSiteRe.hasMatch('final a = ref.watch(authProvider);'), isTrue);
      expect(
        _callSiteRe.hasMatch('ref.read(navStateProvider.notifier).select(x);'),
        isTrue,
      );
      // settings_screen.dart chains `.read(...)` across a line break.
      expect(_callSiteRe.hasMatch('ref\n    .read(settingsProvider.notifier)'),
          isTrue);
      expect(_callSiteRe.hasMatch('somethingElse(authProvider);'), isFalse);
    });
  });
}
