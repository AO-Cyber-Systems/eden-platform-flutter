// Characterization suite for lib/src/entitlements/entitlements_provider.dart.
//
// WHY THIS FILE EXISTS (TRD 50-23). Until now there was none. Every sibling
// notifier in the riverpod alignment — auth, company, nav, settings — had a
// test file to migrate; this 208-line notifier and its five derived providers
// had zero coverage, including the deny-by-default feature gate that the whole
// entitlements UI reads.
//
// These tests were written and made green against the PRE-migration
// `StateNotifier` implementation, BEFORE the port to riverpod 3's `Notifier`.
// That ordering is the entire point: without a control group, "the migration
// preserved behaviour" is an assertion nobody can check. Each test names the
// contract it protects rather than the code path it walks, so a later reader
// learns the rule and not the implementation.
//
// SCOPE NOTE, and it has already caused real confusion twice (50-CONTEXT.md):
// this file covers the eden-biz PLAN/BILLING axis — `/api/v1/entitlements/
// bootstrap`, subscriptions, quotas and plan feature flags. AOID's `ent` claim
// is identity and role, an unrelated system that happens to share the word.
// Nothing here concerns identity, and nothing here ENFORCES anything: these
// providers are UI hinting, and the server always re-verifies.

import 'dart:async';
import 'dart:io';

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers.dart';

// ---------------------------------------------------------------------------
// Local fake. Deliberately NOT in test_helpers.dart: that file is shared and
// was being edited concurrently by 50-21 and 50-22 in this same wave.
// ---------------------------------------------------------------------------

/// [EntitlementsRepository] with a configurable result, a configurable error,
/// an optional [gate] that parks the call on a [Completer], and a call counter.
///
/// The gate matters: a fake that resolves immediately cannot exercise the
/// window during which `isLoading` is true, which is where deny-by-default
/// lives.
class FakeEntitlementsRepository implements EntitlementsRepository {
  EntitlementsBootstrap? bootstrapResult;
  Object? bootstrapError;
  Completer<EntitlementsBootstrap>? gate;

  int calls = 0;
  String? lastAccessToken;
  String? lastCompanyId;
  final List<String> companyIdsRequested = <String>[];

  @override
  Future<EntitlementsBootstrap> bootstrap(String accessToken, String companyId) {
    calls++;
    lastAccessToken = accessToken;
    lastCompanyId = companyId;
    companyIdsRequested.add(companyId);

    final parked = gate;
    if (parked != null) return parked.future;
    if (bootstrapError != null) return Future<EntitlementsBootstrap>.error(bootstrapError!);
    return Future<EntitlementsBootstrap>.value(
        bootstrapResult ?? const EntitlementsBootstrap());
  }
}

// ---------------------------------------------------------------------------
// Fixtures — hand-written from the real entitlements_models.dart types.
// No generated or synthesised data (`no_llm_test_data`).
//
// The shape is chosen so that every NEGATIVE assertion has a fixture in which
// the thing WOULD have happened: `analytics` is allowed, so "denied while
// loading" cannot pass merely because the list is empty; `sso` is present but
// denied, so "denied" cannot pass merely because the key is missing; `seats`
// is a quota and `analytics` is not, so the quota lookup cannot pass by
// returning everything.
// ---------------------------------------------------------------------------

const _plan = PlatformPlan(
  id: 'plan-pro',
  name: 'Pro',
  interval: 'monthly',
  amount: 2900,
  currency: 'usd',
);

const _subscription = PlatformSubscription(
  id: 'sub-1',
  planId: 'plan-pro',
  status: 'active',
);

/// Allowed boolean feature.
const _allowedEntitlement = PlatformEntitlement(
  featureKey: 'analytics',
  featureType: 'boolean',
  allowed: true,
);

/// Present in the plan but explicitly NOT allowed.
const _deniedEntitlement = PlatformEntitlement(
  featureKey: 'sso',
  featureType: 'boolean',
  allowed: false,
);

/// Quota feature, so `isQuota` can be told apart from a boolean one.
const _quotaEntitlement = PlatformEntitlement(
  featureKey: 'seats',
  featureType: 'quota',
  allowed: true,
  includedUnits: 25,
  usedUnits: 10,
  remaining: 15,
);

const _enabledFlag = PlatformFeatureFlag(key: 'new-dashboard', enabled: true);
const _disabledFlag = PlatformFeatureFlag(key: 'beta-export', enabled: false);

const _bootstrap = EntitlementsBootstrap(
  subscription: _subscription,
  plan: _plan,
  entitlements: [_allowedEntitlement, _deniedEntitlement, _quotaEntitlement],
  featureFlags: [_enabledFlag, _disabledFlag],
);

/// A second, visibly different payload — used to prove a reload really
/// replaced the previous company's data rather than leaving it in place.
const _otherCompanyBootstrap = EntitlementsBootstrap(
  subscription: PlatformSubscription(
      id: 'sub-2', planId: 'plan-starter', status: 'trialing'),
  plan: PlatformPlan(
      id: 'plan-starter',
      name: 'Starter',
      interval: 'monthly',
      amount: 900,
      currency: 'usd'),
  entitlements: [
    PlatformEntitlement(
        featureKey: 'analytics', featureType: 'boolean', allowed: false),
  ],
  featureFlags: [PlatformFeatureFlag(key: 'new-dashboard', enabled: false)],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlatformRepository repository;
  late FakeEntitlementsRepository entitlementsRepository;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = FakePlatformRepository();
    entitlementsRepository = FakeEntitlementsRepository()
      ..bootstrapResult = _bootstrap;
    installSecureStorageChannelMock();
  });

  tearDown(uninstallSecureStorageChannelMock);

  /// Settle several rounds: the chain is auth -> company ->
  /// currentCompanyProvider -> entitlements, and each hop is a microtask.
  Future<void> deepSettle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Open a REAL, long-lived subscription to [entitlementsStateProvider].
  ///
  /// Must not be a bare `container.read(...)`. `read` opens a subscription and
  /// closes it immediately, leaving the provider with zero listeners; riverpod
  /// 3 treats an unlistened provider as paused and deactivates the `ref.listen`
  /// subscriptions the element itself created — here, the auth and company
  /// listeners — so the chain never delivers. See
  /// doc/riverpod-3-migration.md §3.2 and §3.10.3.
  ///
  /// Not closed deliberately: `container.dispose()` tears it down.
  void subscribeEntitlements(ProviderContainer container) {
    container.listen<EntitlementsState>(entitlementsStateProvider, (_, _) {});
  }

  /// A container wired with both fakes.
  ///
  /// EVERY container must override `entitlementsRepositoryProvider`: the
  /// default is a real `HttpEntitlementsRepository` pointed at
  /// `http://localhost:9090`, so a test that forgets the override reaches the
  /// network and fails confusingly. No server is started for these tests.
  /// [pinnedCompany] freezes `currentCompanyProvider` at a fixed value so the
  /// company chain cannot clear entitlements out from under an assertion that
  /// is about the notifier alone. (riverpod 3 does not export the `Override`
  /// type from its public barrel, so this is a named knob rather than a
  /// pass-through list.)
  ProviderContainer makeContainer({PlatformCompany? pinnedCompany}) {
    final container = ProviderContainer(overrides: [
      platformRepositoryProvider.overrideWithValue(repository),
      entitlementsRepositoryProvider.overrideWithValue(entitlementsRepository),
      if (pinnedCompany != null)
        currentCompanyProvider.overrideWithValue(pinnedCompany),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  /// Drive the real auth -> company -> entitlements chain to a loaded state.
  Future<ProviderContainer> loggedInContainer({
    String companyId = 'c1',
    List<PlatformCompany>? companies,
    PlatformCompany? pinnedCompany,
  }) async {
    repository
      ..loginResult = buildSession(companyId: companyId)
      ..listCompaniesResult = companies ?? [buildCompany(id: companyId)];
    final container = makeContainer(pinnedCompany: pinnedCompany);
    subscribeEntitlements(container);
    await deepSettle();
    await container.read(authProvider.notifier).login('a@b.com', 'pass');
    await deepSettle();
    return container;
  }

  // =========================================================================
  // 1. The baseline.
  // =========================================================================

  group('the initial state', () {
    test('starts empty and NOT loading, with no plan and no subscription',
        () async {
      final container = makeContainer();
      subscribeEntitlements(container);
      await deepSettle();

      final state = container.read(entitlementsStateProvider);
      expect(state.isLoading, false);
      expect(state.plan, isNull);
      expect(state.subscription, isNull);
      expect(state.entitlements, isEmpty);
      expect(state.featureFlags, isEmpty);
      expect(state.errorMessage, isNull);

      expect(entitlementsRepository.calls, 0,
          reason: 'nothing is fetched until there is both an authenticated '
              'session and a current company');
    });
  });

  // =========================================================================
  // 2. Loading.
  // =========================================================================

  group('load', () {
    test('populates subscription, plan, entitlements and feature flags from '
        'the bootstrap response', () async {
      final container = await loggedInContainer();

      final state = container.read(entitlementsStateProvider);
      expect(state.subscription?.id, 'sub-1');
      expect(state.plan?.id, 'plan-pro');
      expect(state.entitlements.map((e) => e.featureKey),
          containsAll(<String>['analytics', 'sso', 'seats']));
      expect(state.featureFlags.map((f) => f.key),
          containsAll(<String>['new-dashboard', 'beta-export']));
      expect(state.isLoading, false);
      expect(state.errorMessage, isNull);

      expect(entitlementsRepository.calls, greaterThan(0));
      expect(entitlementsRepository.lastCompanyId, 'c1');
      expect(entitlementsRepository.lastAccessToken, 'access-token',
          reason: 'the session access token is what authorises the bootstrap');
    });

    test('with no access token RESETS to the empty state and never reaches '
        'the repository', () async {
      // `currentCompanyProvider` is pinned so the company chain cannot clear
      // entitlements out from under the assertion — this test is about the
      // no-token early return in `load`, nothing else.
      // Pinning `currentCompanyProvider` also means it never TRANSITIONS, so
      // the company listener never fires and the load below is the only one —
      // which is what makes the call counter unambiguous.
      final container =
          await loggedInContainer(pinnedCompany: buildCompany(id: 'c1'));

      // CONTROL: while a token IS present, load() genuinely reaches the
      // repository and populates state — so "did not reach it" below cannot
      // pass vacuously, and there is real data for the early return to clear.
      final callsBefore = entitlementsRepository.calls;
      await container.read(entitlementsStateProvider.notifier).load('c1');
      await deepSettle();
      expect(entitlementsRepository.calls, callsBefore + 1,
          reason: 'CONTROL: with a token the repository IS called');
      expect(container.read(entitlementsStateProvider).plan, isNotNull,
          reason: 'premise: there is data to lose');

      // Empty the access token while staying AUTHENTICATED, so nothing else
      // in the chain clears the state first.
      await container.read(authProvider.notifier).replaceSession(
            accessToken: '',
            refreshToken: 'refresh-token',
          );
      await deepSettle();
      expect(container.read(authProvider).isAuthenticated, true,
          reason: 'premise: still signed in — only the token is empty');
      expect(container.read(entitlementsStateProvider).plan, isNotNull,
          reason: 'premise: the data survived up to the load under test');

      final callsAtEarlyReturn = entitlementsRepository.calls;
      await container.read(entitlementsStateProvider.notifier).load('c1');
      await deepSettle();

      expect(entitlementsRepository.calls, callsAtEarlyReturn,
          reason: 'no token means no bootstrap request at all');
      final state = container.read(entitlementsStateProvider);
      expect(state.plan, isNull);
      expect(state.subscription, isNull);
      expect(state.entitlements, isEmpty);
      expect(state.featureFlags, isEmpty);
      expect(state.isLoading, false);
    });

    test('a FAILURE preserves the plan, subscription, entitlements and flags '
        'already loaded, and surfaces errorMessage', () async {
      // Deliberate contract, not defensiveness: a transient bootstrap failure
      // must not blank the user's plan. A migration that "simplifies" the
      // catch branch to `state = EntitlementsState(errorMessage: ...)` would
      // do exactly that, which is why this is pinned before the port.
      final container = await loggedInContainer();

      expect(container.read(entitlementsStateProvider).plan?.id, 'plan-pro',
          reason: 'premise: there is data to preserve');

      entitlementsRepository.bootstrapError = Exception('bootstrap exploded');
      await container.read(entitlementsStateProvider.notifier).load('c1');
      await deepSettle();

      final state = container.read(entitlementsStateProvider);
      expect(state.errorMessage, contains('bootstrap exploded'));
      expect(state.plan?.id, 'plan-pro');
      expect(state.subscription?.id, 'sub-1');
      expect(state.entitlements.map((e) => e.featureKey),
          containsAll(<String>['analytics', 'sso', 'seats']));
      expect(state.featureFlags.map((f) => f.key), contains('new-dashboard'));
      expect(state.isLoading, false);
    });
  });

  // =========================================================================
  // 3. The derived providers. Five of them, none previously under test.
  // =========================================================================

  group('canUseFeatureProvider — the feature gate', () {
    test('DENIES while loading, even for a feature the plan allows '
        '(deny-by-default)', () async {
      // A SECURITY property, not an implementation detail. riverpod 3 changes
      // when rebuilds happen — `==` filtering, pausing providers whose
      // listeners are all paused — and `isLoading` is observed state, so this
      // is precisely the kind of behaviour a version bump can alter with no
      // compile error.
      //
      // Non-vacuity matters here more than anywhere else in the file: the
      // fixture is loaded FIRST, so `analytics` is present AND allowed at the
      // moment of the assertion. "Returns false" therefore cannot pass because
      // the list is empty; it can only pass because `isLoading` masks it.
      final container = await loggedInContainer();
      container.listen<bool>(canUseFeatureProvider('analytics'), (_, _) {});

      expect(container.read(canUseFeatureProvider('analytics')), true,
          reason: 'premise: the feature is allowed once loaded');

      final gate = Completer<EntitlementsBootstrap>();
      entitlementsRepository.gate = gate;
      unawaited(container.read(entitlementsStateProvider.notifier).load('c1'));
      await Future<void>.delayed(Duration.zero);

      expect(container.read(entitlementsStateProvider).isLoading, true,
          reason: 'premise: a load is genuinely in flight');
      expect(
          container
              .read(entitlementsStateProvider)
              .entitlements
              .any((e) => e.featureKey == 'analytics' && e.allowed),
          true,
          reason: 'premise: the ALLOWED entitlement is still in state, so a '
              'false answer below is deny-by-default and not an empty list');

      expect(container.read(canUseFeatureProvider('analytics')), false,
          reason: 'deny-by-default: no feature is usable while entitlements '
              'are in flight');

      gate.complete(_bootstrap);
      entitlementsRepository.gate = null;
      await deepSettle();

      expect(container.read(canUseFeatureProvider('analytics')), true,
          reason: 'and access is restored once the answer is known');
    });

    test('denies a feature absent from the plan, denies one present but not '
        'allowed, and permits only an allowed one', () async {
      final container = await loggedInContainer();

      expect(container.read(canUseFeatureProvider('analytics')), true,
          reason: 'allowed: true');
      expect(container.read(canUseFeatureProvider('sso')), false,
          reason: 'present in the plan but allowed: false');
      expect(container.read(canUseFeatureProvider('teleportation')), false,
          reason: 'a feature the plan never defines is denied, not permitted');
    });
  });

  group('featureQuotaProvider and featureFlagProvider', () {
    test('the quota lookup returns the entry for a quota feature and null for '
        'a boolean one', () async {
      final container = await loggedInContainer();

      final seats = container.read(featureQuotaProvider('seats'));
      expect(seats, isNotNull);
      expect(seats!.featureKey, 'seats');
      expect(seats.includedUnits, 25);
      expect(seats.remaining, 15);
      expect(seats.isQuota, true);

      expect(container.read(featureQuotaProvider('analytics')), isNull,
          reason: 'analytics is a boolean feature, not a quota — and it IS '
              'present in state, so null here is the isQuota filter working '
              'rather than a missing key');
      expect(container.read(featureQuotaProvider('teleportation')), isNull,
          reason: 'an undefined feature has no quota');
    });

    test('the flag lookup reports enabled, disabled and unknown flags '
        'distinctly', () async {
      final container = await loggedInContainer();

      expect(container.read(featureFlagProvider('new-dashboard')), true);
      expect(container.read(featureFlagProvider('beta-export')), false,
          reason: 'present but disabled');
      expect(container.read(featureFlagProvider('no-such-flag')), false,
          reason: 'an unknown flag is off, never on');
    });

    test('currentPlanProvider and currentSubscriptionProvider expose the '
        'loaded plan and subscription', () async {
      final container = await loggedInContainer();

      expect(container.read(currentPlanProvider)?.id, 'plan-pro');
      expect(container.read(currentPlanProvider)?.name, 'Pro');
      expect(container.read(currentSubscriptionProvider)?.id, 'sub-1');
      expect(container.read(currentSubscriptionProvider)?.isActive, true);
    });
  });

  // =========================================================================
  // 4. The company listener.
  // =========================================================================

  group('the currentCompanyProvider listener', () {
    test('a company id CHANGE reloads entitlements for the new company',
        () async {
      final container = await loggedInContainer(
        companyId: 'c1',
        companies: [buildCompany(id: 'c1'), buildCompany(id: 'c2')],
      );

      expect(container.read(currentCompanyProvider)?.id, 'c1',
          reason: 'premise: loaded for c1 before the switch');
      expect(container.read(canUseFeatureProvider('analytics')), true,
          reason: 'premise: c1 allows analytics');

      final callsBefore = entitlementsRepository.calls;
      entitlementsRepository.bootstrapResult = _otherCompanyBootstrap;

      await container
          .read(companyStateProvider.notifier)
          .setCompany(buildCompany(id: 'c2'));
      await deepSettle();

      expect(entitlementsRepository.calls - callsBefore, 1,
          reason: 'exactly one reload for the new company');
      expect(entitlementsRepository.lastCompanyId, 'c2');
      expect(container.read(currentPlanProvider)?.id, 'plan-starter',
          reason: "the previous company's plan must be replaced, not kept");
      expect(container.read(canUseFeatureProvider('analytics')), false,
          reason: 'c2 does not allow analytics — this is the multi-tenant '
              'residue path');
    });

    test('re-setting the SAME company id does not reload', () async {
      final container = await loggedInContainer(companyId: 'c1');

      final callsBefore = entitlementsRepository.calls;
      expect(callsBefore, greaterThan(0),
          reason: 'premise: at least one load has happened, so a second would '
              'be visible');

      await container
          .read(companyStateProvider.notifier)
          .setCompany(buildCompany(id: 'c1'));
      await deepSettle();

      expect(entitlementsRepository.calls, callsBefore,
          reason: '`previous?.id != next.id` must gate the reload');
    });
  });

  // =========================================================================
  // 5. refresh.
  // =========================================================================

  group('refresh', () {
    test('reloads for the current company', () async {
      final container = await loggedInContainer(companyId: 'c1');

      final callsBefore = entitlementsRepository.calls;
      await container.read(entitlementsStateProvider.notifier).refresh();
      await deepSettle();

      expect(entitlementsRepository.calls, callsBefore + 1);
      expect(entitlementsRepository.lastCompanyId, 'c1');
    });

    test('is a no-op when there is no current company, even while the session '
        'is still valid', () async {
      // The session is deliberately kept AUTHENTICATED. Signing out to remove
      // the company would make this assertion pass for the wrong reason: with
      // no access token, load()'s early return would swallow a wrongly-issued
      // refresh before it ever reached the repository, so a `refresh` that had
      // lost its null guard would look like a no-op. MEASURED: mutating
      // `refresh` to `load(company?.id ?? '')` SURVIVES the sign-out version
      // of this test and is killed only by this one.
      final container = await loggedInContainer(companyId: 'c1');

      container.read(companyStateProvider.notifier).clear();
      await deepSettle();

      expect(container.read(currentCompanyProvider), isNull,
          reason: 'premise: no current company');
      expect(container.read(authProvider).accessToken, isNotNull,
          reason: 'premise: the session is still valid, so a wrongly-issued '
              'load WOULD reach the repository');

      final callsBefore = entitlementsRepository.calls;
      expect(callsBefore, greaterThan(0),
          reason: 'premise: refresh HAS reached the repository before, so a '
              'call here would be visible');

      await container.read(entitlementsStateProvider.notifier).refresh();
      await deepSettle();

      expect(entitlementsRepository.calls, callsBefore,
          reason: 'no company means nothing to refresh');
    });
  });

  // =========================================================================
  // 6. The isolation assertion — the logout chain's third link.
  //
  // auth -> company -> currentCompanyProvider -> nav -> entitlements.
  // If a sign-out does not clear here, one account's plan, quotas and feature
  // flags survive into the next session.
  // =========================================================================

  group('logout chain', () {
    test('a sign-out clears the plan, subscription, entitlements and flags',
        () async {
      final container = await loggedInContainer(companyId: 'c1');

      // PREMISE. Every field must be POPULATED, or the "is empty" assertions
      // below are vacuously true and this test proves nothing. A logout test
      // invites exactly that trap.
      expect(container.read(entitlementsStateProvider).plan, isNotNull);
      expect(container.read(entitlementsStateProvider).subscription, isNotNull);
      expect(container.read(entitlementsStateProvider).entitlements, isNotEmpty);
      expect(container.read(entitlementsStateProvider).featureFlags, isNotEmpty);
      expect(container.read(currentPlanProvider), isNotNull);
      expect(container.read(currentSubscriptionProvider), isNotNull);
      expect(container.read(canUseFeatureProvider('analytics')), true);
      expect(container.read(featureFlagProvider('new-dashboard')), true);
      expect(container.read(featureQuotaProvider('seats')), isNotNull);

      await container.read(authProvider.notifier).logout();
      await deepSettle();

      final state = container.read(entitlementsStateProvider);
      expect(state.plan, isNull);
      expect(state.subscription, isNull);
      expect(state.entitlements, isEmpty);
      expect(state.featureFlags, isEmpty);
      expect(state.isLoading, false);

      // The derived providers must agree — they are what the UI reads.
      expect(container.read(currentPlanProvider), isNull);
      expect(container.read(currentSubscriptionProvider), isNull);
      expect(container.read(canUseFeatureProvider('analytics')), false,
          reason: "the next session must not inherit the previous tenant's "
              'feature access');
      expect(container.read(featureFlagProvider('new-dashboard')), false);
      expect(container.read(featureQuotaProvider('seats')), isNull);
    });

    test('losing the current company clears entitlements even while the '
        'session stays valid — the company route is its own route', () async {
      // The sign-out test CANNOT see this. Entitlements listens to
      // `authProvider` directly as well, so on a sign-out the auth route
      // clears the state and the company route's `if (next == null) clear()`
      // is redundant. MEASURED: deleting that branch SURVIVES the whole suite
      // except this test.
      //
      // It is not redundant in production: a company can go null while the
      // session is still valid — a tenant switch that resolves to nothing, a
      // membership revoked underneath the user. Without this branch the
      // previous company's plan, quotas and feature flags stay on screen, and
      // that is the multi-tenant residue path this objective targets.
      final container = await loggedInContainer(companyId: 'c1');

      expect(container.read(entitlementsStateProvider).plan, isNotNull,
          reason: 'premise: populated for c1');
      expect(container.read(canUseFeatureProvider('analytics')), true);

      container.read(companyStateProvider.notifier).clear();
      await deepSettle();

      expect(container.read(authProvider).isAuthenticated, true,
          reason: 'premise: still signed in — only the company went away, so '
              'the auth route CANNOT be what clears this');
      expect(container.read(currentCompanyProvider), isNull);

      final state = container.read(entitlementsStateProvider);
      expect(state.plan, isNull);
      expect(state.subscription, isNull);
      expect(state.entitlements, isEmpty);
      expect(state.featureFlags, isEmpty);
      expect(container.read(canUseFeatureProvider('analytics')), false);
    });

    test('clearing twice leaves everything clear', () async {
      final container = await loggedInContainer(companyId: 'c1');
      expect(container.read(entitlementsStateProvider).plan, isNotNull,
          reason: 'premise: there is something to clear');

      container.read(entitlementsStateProvider.notifier).clear();
      await deepSettle();
      container.read(entitlementsStateProvider.notifier).clear();
      await deepSettle();

      final state = container.read(entitlementsStateProvider);
      expect(state.plan, isNull);
      expect(state.subscription, isNull);
      expect(state.entitlements, isEmpty);
      expect(state.featureFlags, isEmpty);
    });

    test('a repeat clear() still NOTIFIES, despite the const sentinel',
        () async {
      // THE CONST-SENTINEL NOTIFICATION HAZARD. `clear()` assigns
      // `const EntitlementsState()`, which Dart canonicalizes to ONE object
      // forever. riverpod 3 filters updates with `previous != next`, and
      // `EntitlementsState` declares no `operator ==`, so `!=` degrades to
      // identity: re-assigning the sentinel a provider already holds is
      // invisible. What is lost is the SIGNAL, not the value.
      //
      // MEASURED on the pre-migration StateNotifier code, fires on the SECOND
      // sign-out (the first was never broken):
      //   entitlementsStateProvider 0 · currentPlanProvider 0 ·
      //   currentSubscriptionProvider 0 · canUseFeatureProvider 0
      // So this PREDATES the riverpod bump — `StateNotifier`'s own
      // `!identical` default is the same predicate. Fourth occurrence in this
      // objective, after AuthState (50-21), CompanyState and NavState (50-22).
      final container = await loggedInContainer(companyId: 'c1');
      final fires = <String?>[];
      container.listen<EntitlementsState>(
          entitlementsStateProvider, (_, n) => fires.add(n.plan?.id));

      expect(container.read(entitlementsStateProvider).plan, isNotNull,
          reason: 'premise: populated, so the first clear is a real change');

      container.read(entitlementsStateProvider.notifier).clear();
      await deepSettle();
      expect(fires, isNotEmpty, reason: 'the first clear is never the problem');

      // PREMISE: the provider now holds the canonicalized sentinel, so the
      // next assignment is sentinel-to-identical-sentinel — the dropped case.
      fires.clear();
      container.read(entitlementsStateProvider.notifier).clear();
      await deepSettle();

      expect(fires, isNotEmpty,
          reason: 'a consumer holding a ref.listen on this provider to drop '
              "the previous tenant's cached plan never hears the second "
              'clear — restored by EntitlementsNotifier.updateShouldNotify');
    });

    test('the no-token early return in load() ALSO notifies on a repeat — so '
        'a de-consted clear() cannot pass for a whole-class fix', () async {
      // `clear()` is NOT the only place this notifier assigns the sentinel:
      // load()'s no-access-token early return does `state = const
      // EntitlementsState()` too. 50-22 measured that de-consting `clear()`
      // alone PASSES the entire clear-based chain test while leaving every
      // early-return path suppressed — a silent PARTIAL fix with a green
      // suite. This test is what tells the two remedies apart, and it is why
      // the fix belongs on the notifier (`updateShouldNotify`) rather than on
      // the shape of one assignment.
      final container = await loggedInContainer(companyId: 'c1');
      final fires = <String?>[];
      container.listen<EntitlementsState>(
          entitlementsStateProvider, (_, n) => fires.add(n.plan?.id));

      await container.read(authProvider.notifier).logout();
      await deepSettle();
      expect(container.read(authProvider).accessToken, isNull,
          reason: 'premise: the no-token early return is the path taken');

      // Drive the early return ONCE, so the provider is holding the sentinel
      // the early return itself produced — a state a de-consted clear() can
      // never arrange.
      final callsBefore = entitlementsRepository.calls;
      await container.read(entitlementsStateProvider.notifier).load('c1');
      await deepSettle();
      expect(entitlementsRepository.calls, callsBefore,
          reason: 'premise: the early return was taken, not a real fetch');

      // ...and again. THIS is the suppressed assignment.
      fires.clear();
      await container.read(entitlementsStateProvider.notifier).load('c1');
      await deepSettle();

      expect(fires, isNotEmpty,
          reason: "load()'s no-token `state = const EntitlementsState()` must "
              'still notify when the provider already holds that sentinel');
    });

    test('the DERIVED providers legitimately stay silent on a repeat clear, '
        'and that is not a bug to chase', () async {
      // A plain `Provider` runs its OWN `previous != next` filter
      // (riverpod-3.3.2 providers/provider.dart:349), which an upstream
      // notifier's `updateShouldNotify` cannot punch through. On a repeat
      // clear these genuinely do not change — null -> null — so there is
      // nothing stale. Asserted explicitly so a later reader does not chase
      // it, and so the distinction between notifier and derived stays visible.
      final container = await loggedInContainer(companyId: 'c1');
      final planFires = <String?>[];
      final subFires = <String?>[];
      container.listen<PlatformPlan?>(
          currentPlanProvider, (_, n) => planFires.add(n?.id));
      container.listen<PlatformSubscription?>(
          currentSubscriptionProvider, (_, n) => subFires.add(n?.id));

      container.read(entitlementsStateProvider.notifier).clear();
      await deepSettle();
      expect(planFires, isNotEmpty,
          reason: 'premise: the FIRST clear does reach the derived providers');

      planFires.clear();
      subFires.clear();
      container.read(entitlementsStateProvider.notifier).clear();
      await deepSettle();

      expect(planFires, isEmpty);
      expect(subFires, isEmpty);
      expect(container.read(currentPlanProvider), isNull,
          reason: 'and the VALUE is correct regardless — nothing is stale');
    });

    test('PREMISE GUARDS: the sentinel really is canonicalized and '
        'EntitlementsState really has no value ==', () {
      // If either premise stops holding, the notification tests elsewhere in
      // this file would pass for the wrong reason. Dart canonicalizes const
      // instances, so `clear()`'s `const EntitlementsState()` is ONE object...
      expect(identical(const EntitlementsState(), const EntitlementsState()),
          true);
      // ...and the class declares no `operator ==`, so two structurally
      // identical NON-const instances compare unequal. That is what makes
      // riverpod 3's `previous != next` degrade to an identity test — and what
      // makes it the SAME predicate as StateNotifier's `!identical` default,
      // which is why this hazard predates the version bump.
      expect(EntitlementsState() == EntitlementsState(), false);
    });
  });

  // =========================================================================
  // 7. The port itself: wiring that used to live in the provider closure now
  //    lives in build(), so it has to survive a rebuild.
  // =========================================================================

  group('the wiring survives a rebuild', () {
    test('after an invalidate, ONE company change still produces exactly ONE '
        'reload — the listeners re-register without duplicating', () async {
      // riverpod owns re-registration across rebuilds. An "already registered"
      // flag would leak the first subscription; conversely a double
      // registration would load twice per switch and race the two responses.
      final container = await loggedInContainer(
        companyId: 'c1',
        companies: [buildCompany(id: 'c1'), buildCompany(id: 'c2')],
      );

      // CONTROL: one switch, one load, on the ORIGINAL build.
      var before = entitlementsRepository.calls;
      await container
          .read(companyStateProvider.notifier)
          .setCompany(buildCompany(id: 'c2'));
      await deepSettle();
      expect(entitlementsRepository.calls - before, 1,
          reason: 'CONTROL: one switch is one load before any rebuild');

      container.invalidate(entitlementsStateProvider);
      subscribeEntitlements(container);
      await deepSettle();

      before = entitlementsRepository.calls;
      await container
          .read(companyStateProvider.notifier)
          .setCompany(buildCompany(id: 'c1'));
      await deepSettle();

      expect(entitlementsRepository.calls - before, 1,
          reason: 'exactly one reload after the rebuild — not zero (a leaked '
              'subscription) and not two (a duplicated one)');
    });

    test('a riverpod 3 Notifier instance is REUSED across a rebuild', () async {
      // Recorded because the TRD body claims the opposite in two places, and
      // it decides whether fields outside `state` need resetting in build().
      // This notifier keeps none, so the reuse is currently harmless — but a
      // future contributor adding one needs to know which way it goes.
      final container = await loggedInContainer(companyId: 'c1');
      final first = container.read(entitlementsStateProvider.notifier);

      container.invalidate(entitlementsStateProvider);
      subscribeEntitlements(container);
      await deepSettle();

      expect(identical(first, container.read(entitlementsStateProvider.notifier)),
          true,
          reason: 'the instance is reused, not reconstructed — unlike the '
              'StateNotifierProvider this replaced');
    });

    test('the provider is KEEP-ALIVE: state survives the last listener '
        'detaching', () async {
      // `NotifierProvider(..., isAutoDispose: false)` is the default, so a
      // plain port preserves the lifetime StateNotifierProvider had. Setting
      // it by accident is invisible to almost every test.
      //
      // The pump below is load-bearing: riverpod SCHEDULES disposal rather
      // than running it inside close(), so a synchronous read after detaching
      // observes the pre-disposal value and this assertion would pass even
      // with isAutoDispose: true. 50-22 measured exactly that survival.
      final container = await loggedInContainer(companyId: 'c1');
      final sub = container.listen<EntitlementsState>(
          entitlementsStateProvider, (_, _) {});
      expect(container.read(entitlementsStateProvider).plan?.id, 'plan-pro',
          reason: 'premise: loaded before detaching');

      sub.close();
      await deepSettle(); // <- without this the mutation survives

      expect(container.read(entitlementsStateProvider).plan?.id, 'plan-pro',
          reason: 'an auto-disposing provider would have reset to the empty '
              'state here');
    });
  });

  // =========================================================================
  // 8. Source-level facts.
  //
  // A whole-file `grep` cannot tell a DECLARATION from a MENTION, and this
  // file's dartdoc deliberately names the old base class to explain the port.
  // These assertions strip `//` comment lines and check CODE only, with two
  // guards on the stripper itself so it cannot pass by removing everything.
  // =========================================================================

  group('source', () {
    late String src;
    late String code;

    setUp(() {
      src = File('lib/src/entitlements/entitlements_provider.dart')
          .readAsStringSync();
      code = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
    });

    test('the comment stripper is sound', () {
      expect(src.length, greaterThan(2000),
          reason: 'the file must actually have been read');
      expect(code.length, lessThan(src.length),
          reason: 'stripping must actually have removed something');
      expect(code.contains('class EntitlementsNotifier'), true,
          reason: 'stripping must not have removed the declaration');
    });

    test('all five derived providers keep their identifiers, and so do the '
        'two entry points', () {
      // 50-24 migrates feature_gate.dart, quota_bar.dart and plan_badge.dart,
      // which read these by name. Renaming any of them breaks that TRD.
      for (final id in <String>[
        'final entitlementsRepositoryProvider =',
        'final entitlementsStateProvider =',
        'final canUseFeatureProvider =',
        'final featureQuotaProvider =',
        'final featureFlagProvider =',
        'final currentPlanProvider =',
        'final currentSubscriptionProvider =',
      ]) {
        expect(code.contains(id), true, reason: 'missing: $id');
      }
    });

    test('the notifier is on riverpod 3 Notifier, with the Stage A shim gone '
        'and the Ref field removed', () {
      // A whole-file grep cannot tell a DECLARATION from a MENTION, and the
      // dartdoc above deliberately names the old base class to explain the
      // port. These assertions run against comment-stripped CODE.
      expect(
          code.contains('class EntitlementsNotifier extends '
              'Notifier<EntitlementsState>'),
          true);

      // Assembled so this source file does not itself contain the banned
      // token, which would make the assertion self-defeating.
      final banned = ['State', 'Notifier'].join();
      expect(code.contains(banned), false,
          reason: 'no StateNotifier or StateNotifierProvider remains in code');

      final legacyImport = "flutter_riverpod/${'legacy'}.dart";
      expect(src.contains("import 'package:$legacyImport'"), false,
          reason: 'the Stage A shim import is removed — this is how 50-24 '
              'knows this notifier is done');

      expect(RegExp(r'final\s+Ref\s+ref\s*;').hasMatch(code), false,
          reason: 'Notifier supplies ref; a shadowing field compiles while '
              'behaving differently across rebuilds');
      expect(code.contains('EntitlementsNotifier(this.ref)'), false);

      expect(
          code.contains('NotifierProvider<EntitlementsNotifier, '
              'EntitlementsState>(\n        EntitlementsNotifier.new)'),
          true,
          reason: 'provider converted, identifier unchanged');
    });

    test('all the wiring moved into build(), listeners before the bootstrap',
        () {
      expect('ref.listen'.allMatches(code).length, 2,
          reason: 'the auth listener AND the company listener');
      expect('Future.microtask'.allMatches(code).length, 1,
          reason: 'the single bootstrap');
      expect(code.indexOf('ref.listen'),
          lessThan(code.indexOf('Future.microtask')),
          reason: 'listeners registered before the bootstrap is scheduled');

      // Everything must be inside build(), not left at top level.
      final build = code.substring(
        code.indexOf('EntitlementsState build()'),
        code.indexOf('bool updateShouldNotify'),
      );
      expect('ref.listen'.allMatches(build).length, 2);
      expect('Future.microtask'.allMatches(build).length, 1);
    });

    test('the const sentinel is assigned from TWO sites, which is why the '
        'remedy is updateShouldNotify and not a de-consted clear()', () {
      // If a future contributor "fixes" the notification hazard by dropping
      // the const from clear(), this pins that the early return is a second
      // site and would still be suppressed. It also fails loudly if
      // updateShouldNotify is ever removed.
      expect('const EntitlementsState()'.allMatches(code).length,
          greaterThanOrEqualTo(2),
          reason: 'clear() and load()\'s no-token early return');
      expect(code.contains('bool updateShouldNotify'), true,
          reason: 'the whole-class remedy must be present');
    });

    test('the UI-hinting and billing-axis framing is documented in the file',
        () {
      // 50-CONTEXT.md documentation requirements. Both have already caused
      // real confusion, so they are asserted rather than trusted.
      expect(RegExp(r'hinting', caseSensitive: false).hasMatch(src), true,
          reason: 'the file must say these providers are UI hinting');
      expect(
          RegExp(r'server\s+always\s+re-verif', caseSensitive: false)
              .hasMatch(src),
          true,
          reason: 'the file must say the server re-verifies');
      expect(RegExp(r'billing', caseSensitive: false).hasMatch(src), true,
          reason: 'the file must name the eden-biz plan/billing axis');
      expect(RegExp(r'`ent`\s+claim', caseSensitive: false).hasMatch(src), true,
          reason: "the file must distinguish AOID's identity `ent` claim");
    });

    test('EntitlementsState is never given a value operator ==', () {
      // The remedy for the const-sentinel hazard is scoped to the notifier.
      // An `operator ==` here would change equality for every consumer in 18+
      // packages to fix one notification.
      expect(code.contains('operator =='), false);
    });
  });
}
