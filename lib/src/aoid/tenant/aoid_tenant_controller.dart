// SDK-07 — the client half of AOID's active-tenant switch.
//
// The server side is complete and verified; before this file the client's
// entire "switch company" was one SharedPreferences write and a local state
// update (lib/src/company/company_provider.dart:96-100) — no round trip, no
// token re-issue.
//
// ## Riverpod-free ON PURPOSE, and it is not vestigial
//
// `AoidTenantController` is a plain `ChangeNotifier`. That is a decision, not
// a leftover from the firewall the barrel consolidation deleted:
//
// * riverpod 3 RETRIES a failed provider automatically — 10 attempts over a
//   38.2-second window — declining only for `ProviderException` and `Error`
//   (`element.dart:685`). A tenant DENIAL is an ordinary `Exception`, so a
//   controller expressed as a `Notifier` would re-probe a refusal ten times
//   and, via `AsyncValue.when()`'s `isLoading`-first ordering
//   (`async_value.dart:250`), render a spinner instead of the refusal for the
//   whole window. Consumers that DO wrap this in a provider must pass
//   `aoidTenantSwitchRetry` as `retry:` — see its doc comment.
// * A riverpod 3 `Notifier`'s `state` does not exist until the provider is
//   first READ, and touching it early throws `Bad state: Tried to use a
//   notifier in an uninitialized state` at RUNTIME only — it compiles and
//   passes `flutter analyze`. A tenant controller reached from a router
//   redirect is exactly where that fires. A `ChangeNotifier` holds its own
//   state and structurally cannot.
// * `ChangeNotifier.notifyListeners()` applies NO `==` filter, so a switch
//   BACK to a tenant already seen still notifies. riverpod 3 filters every
//   update by `==` and a const sentinel is canonicalized to the identical
//   object, which is how a clear/switch path silently leaves the previous
//   tenant's data resident. `AuthNotifier` had to override
//   `updateShouldNotify` to get this back; here it is free.
//
// NOTE for a future editor: this class holds NO timer, stream subscription or
// other resource, so it deliberately overrides nothing in `dispose()`. If you
// ever add one, remember that porting this to a riverpod `Notifier` would give
// you a class with no `dispose()` to override at all — the mistake is a
// WARNING, not an error, so the teardown would leak straight past an
// errors-only gate. Use `ref.onDispose()` there.

import 'package:flutter/foundation.dart';

import '../claims/aoid_claims.dart';
import '../claims/tenant_ref.dart';
import '../mode/aoid_deployment_mode.dart';
import '../transport/aoid_error.dart';
import '../transport/aoid_token_client.dart';
import 'aoid_refresh_single_flight.dart';

/// What a deployment's switch mechanism produced.
///
/// Both fields are nullable because the three D4 modes genuinely differ:
/// Mode B returns a full rotated pair, Mode A returns an access token with the
/// refresh token held by the app's backend, and Mode C returns neither because
/// the session IS the cookie.
final class AoidTenantSwitchOutcome {
  const AoidTenantSwitchOutcome({this.accessToken, this.refreshToken});

  /// The NEW access token. When present it is what the switch is VERIFIED
  /// against — never the id_token, whose `tnt` deliberately does not follow
  /// the switch (aoid the token claims`).
  final String? accessToken;

  /// The ROTATED refresh token, when this deployment holds one client-side.
  final String? refreshToken;
}

/// HOW a deployment performs the switch. One implementation per D4 posture, so
/// the CALLER never branches on mode (the test list item 7).
abstract class AoidTenantSwitchBackend {
  /// The D4 mode this backend implements.
  AoidDeploymentMode get mode;

  /// Whether the client holds the token pair and must persist a rotation.
  /// True in exactly one mode: [AoidDeploymentMode.publicPkce].
  bool get persistsTokenPair;

  /// Perform the switch to [target].
  Future<AoidTenantSwitchOutcome> switchTo(AoidActiveTenantSlug target);

  /// An ORDINARY rotation, with no tenant change. Wired into
  /// `ProactiveRefresh.restoreSession` so both paths share one slot.
  Future<AoidTenantSwitchOutcome> refresh();
}

/// **Mode B** — the switch IS a refresh grant carrying `active_tenant`.
final class AoidRefreshGrantBackend implements AoidTenantSwitchBackend {
  const AoidRefreshGrantBackend({
    required AoidTokenClient tokenClient,
    required Future<String?> Function() readRefreshToken,
  }) : _tokenClient = tokenClient,
       _readRefreshToken = readRefreshToken;

  final AoidTokenClient _tokenClient;
  final Future<String?> Function() _readRefreshToken;

  @override
  AoidDeploymentMode get mode => AoidDeploymentMode.publicPkce;

  @override
  bool get persistsTokenPair => true;

  @override
  Future<AoidTenantSwitchOutcome> switchTo(AoidActiveTenantSlug target) =>
      _grant(target);

  @override
  Future<AoidTenantSwitchOutcome> refresh() => _grant(null);

  Future<AoidTenantSwitchOutcome> _grant(AoidActiveTenantSlug? target) async {
    final refreshToken = await _readRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      // No credential to present. NOT a denial — do not let this become one,
      // or a signed-out client would report "that workspace could not be
      // selected" forever instead of prompting for sign-in.
      throw const AoidError(AoidErrorCode.invalidSession);
    }
    final response = await _tokenClient.refresh(
      refreshToken: refreshToken,
      activeTenant: target,
    );
    return AoidTenantSwitchOutcome(
      accessToken: response.accessToken,
      refreshToken: response.refreshToken,
    );
  }
}

/// **Modes A and C** — the session cookie is swapped SERVER-side.
///
/// Mode A hands the switch to the consuming app's own backend (the
/// `AoidCodeSink` seam's sibling; the app's backend builds AODex's endpoint against this
/// shape). Mode C is same-origin, so the browser's own cookie carries it.
/// Neither returns a refresh token to the client, and neither may call
/// `replaceSession` — persisting the empty strings would clobber real values.
final class AoidCookieSwitchBackend implements AoidTenantSwitchBackend {
  const AoidCookieSwitchBackend({
    required this.mode,
    required Future<AoidTenantSwitchOutcome> Function(AoidActiveTenantSlug)
    performSwitch,
    required Future<AoidTenantSwitchOutcome> Function() performRefresh,
  }) : _performSwitch = performSwitch,
       _performRefresh = performRefresh;

  @override
  final AoidDeploymentMode mode;

  final Future<AoidTenantSwitchOutcome> Function(AoidActiveTenantSlug)
  _performSwitch;
  final Future<AoidTenantSwitchOutcome> Function() _performRefresh;

  @override
  bool get persistsTokenPair => false;

  @override
  Future<AoidTenantSwitchOutcome> switchTo(AoidActiveTenantSlug target) =>
      _performSwitch(target);

  @override
  Future<AoidTenantSwitchOutcome> refresh() => _performRefresh();
}

/// Switches the ACTIVE TENANT, deny-by-default, without signing anyone out.
///
/// ```dart
/// final controller = AoidTenantController(
///   backend: AoidRefreshGrantBackend(
///     tokenClient: tokenClient,
///     readRefreshToken: tokenStore.readRefreshToken,
///   ),
///   replaceSession: ref.read(authProvider.notifier).replaceSession,
///   onTenantChanged: (slug) => ref.invalidate(myTenantScopedProvider),
/// );
/// ```
class AoidTenantController extends ChangeNotifier {
  AoidTenantController({
    required AoidTenantSwitchBackend backend,
    AoidRefreshSingleFlight? singleFlight,
    Future<void> Function({
      required String accessToken,
      required String refreshToken,
    })?
    replaceSession,
    void Function(AoidActiveTenantSlug slug)? onTenantChanged,
    AoidActiveTenantSlug? activeTenant,
  }) : _backend = backend,
       _singleFlight = singleFlight ?? AoidRefreshSingleFlight(),
       _replaceSession = replaceSession,
       _onTenantChanged = onTenantChanged,
       _activeTenant = activeTenant;

  final AoidTenantSwitchBackend _backend;
  final AoidRefreshSingleFlight _singleFlight;
  final Future<void> Function({
    required String accessToken,
    required String refreshToken,
  })?
  _replaceSession;
  final void Function(AoidActiveTenantSlug slug)? _onTenantChanged;

  AoidActiveTenantSlug? _activeTenant;
  bool _switching = false;
  bool _lastSwitchVerified = false;

  /// The slot every rotation passes through.
  ///
  /// Hand this to `ProactiveRefresh` — or rather, hand it
  /// [refreshSession], which is the same slot reached through
  /// `ProactiveRefresh`'s existing `restoreSession` seam.
  AoidRefreshSingleFlight get singleFlight => _singleFlight;

  /// True while a switch is in flight, so the UI can disable the control.
  bool get switching => _switching;

  /// The client's belief about the active tenant.
  ///
  /// A HINT decoded from an unverified token, never authority — which is why
  /// [switchTo] does not short-circuit when asked for this same value.
  AoidActiveTenantSlug? get activeTenant => _activeTenant;

  /// Whether the last successful switch was CONFIRMED against a claim.
  ///
  /// False in Mode C, where no access token reaches the client and there is
  /// nothing to decode. Exposed rather than papered over: "we could not check"
  /// and "we checked and it was right" are different facts.
  bool get lastSwitchVerified => _lastSwitchVerified;

  /// Switch the active tenant to [target].
  ///
  /// [target] is an [AoidActiveTenantSlug] and nothing else, so passing the
  /// id_token's home-tenant UUID is a COMPILE error rather than a runtime
  /// `invalid_grant` (D5). This is the one call site where that mistake would
  /// actually be made.
  ///
  /// Throws:
  /// * `AoidTenantDenied` when AOID refuses the target. **Do not treat this as
  ///   an authentication failure** — it is a permission answer, and routing it
  ///   into a sign-out path is the defect this whole module exists to prevent.
  /// * [AoidTransportError] when the switch could not be confirmed, including
  ///   the case where AOID answered 200 with a token for a DIFFERENT tenant.
  ///
  /// On success, fires [ChangeNotifier] listeners and then `onTenantChanged`.
  Future<AoidActiveTenantSlug> switchTo(AoidActiveTenantSlug target) async {
    _switching = true;
    notifyListeners();
    try {
      // EXCLUSIVE, not `join`: attaching to somebody else's rotation would
      // report success while the active tenant never moved.
      final outcome = await _singleFlight.runExclusive(
        () => _backend.switchTo(target),
      );

      // ── PERSIST FIRST, VERIFY SECOND. The order is load-bearing. ──────────
      //
      // A successful grant has ALREADY rotated the refresh token server-side.
      // Verifying first and discarding the new pair on a mismatch would leave
      // the client holding a token the server has retired — so the very next
      // refresh fails and the user is signed out. That is the same bug this
      // module exists to prevent, arriving by a different route.
      //
      // Persisting a pair for a tenant that turns out to be wrong is harmless:
      // it is a VALID session, merely not the one that was asked for, and the
      // failed verification below stops the client from believing otherwise.
      await _persist(outcome);

      _lastSwitchVerified = false;
      final accessToken = outcome.accessToken;
      if (accessToken != null && accessToken.isNotEmpty) {
        // The ACCESS token. Decoding the id_token would ALWAYS fail here: its
        // `tnt` is the home tenant's UUID and does not follow the switch.
        final claims = AoidAccessClaims.decodeUnverified(accessToken);
        if (claims.activeTenant.slug != target.slug) {
          // AOID answered 200 for a tenant that is not the one requested. Not
          // a denial (nothing was refused) and not an auth failure (the
          // session is fine) — the response did not mean what it must mean.
          throw const AoidTransportError(
            AoidTransportFailureKind.malformed,
            statusCode: 200,
          );
        }
        _lastSwitchVerified = true;
      }

      // Only NOW does the client's belief move.
      _activeTenant = target;
      notifyListeners();

      // AFTER the session was replaced, never before: an app that invalidates
      // its caches while the OLD access token is still live refills them with
      // the OLD tenant's data. The SDK cannot invalidate for the app, and a
      // slug is not a credential (D3), so the hook carries the slug and
      // nothing else.
      _onTenantChanged?.call(target);
      return target;
    } finally {
      _switching = false;
      notifyListeners();
    }
  }

  /// An ORDINARY refresh, through the SAME slot as [switchTo].
  ///
  /// Wire this into `ProactiveRefresh`:
  ///
  /// ```dart
  /// ProactiveRefresh(
  ///   getAccessToken: () => ref.read(authProvider).accessToken,
  ///   restoreSession: controller.refreshSession,
  /// );
  /// ```
  ///
  /// A refresh arriving while a switch is in flight ATTACHES to it — the
  /// switch is a refresh with an extra parameter, so it satisfies both and
  /// only one request is made.
  Future<void> refreshSession() => _singleFlight.join(() async {
    await _persist(await _backend.refresh());
  });

  Future<void> _persist(AoidTenantSwitchOutcome outcome) async {
    if (!_backend.persistsTokenPair) return;
    final accessToken = outcome.accessToken;
    final refreshToken = outcome.refreshToken;
    if (accessToken == null || refreshToken == null) {
      // A client-held deployment that got back half a pair. Persisting half
      // would wedge the session; say the response was malformed instead.
      throw const AoidTransportError(AoidTransportFailureKind.malformed);
    }
    await _replaceSession?.call(
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
  }
}
