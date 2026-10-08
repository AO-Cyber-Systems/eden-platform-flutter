// The AOID native ceremony state machine — the CONTROLLER the widgets layer's sealed
// AoidLoginForm drives.
//
// RIVERPOD-FREE and Flutter-free: reachable from lib/aoid.dart.

import '../../auth/native_ceremony.dart';
import '../../auth/auth_strategy.dart' show RedirectRequired;
import '../claims/tenant_ref.dart' show AoidActiveTenantSlug;
import '../passkey/aoid_passkey_authenticator.dart';
import '../transport/aoid_error.dart';
import '../transport/aoid_native_client.dart';
import 'aoid_passkey_outcome.dart';

/// What [AoidNativeFlow.begin] was last called with. Private: a restart replays
/// it, and nothing outside the flow reads it.
typedef _BeginArgs = ({
  String codeChallenge,
  List<String> scopes,
  String? nonce,
  AoidActiveTenantSlug? activeTenant,
  String? loginHint,
});

/// Where the ceremony currently stands.
sealed class AoidFlowState {
  const AoidFlowState();
}

/// Nothing started yet.
final class AoidFlowIdle extends AoidFlowState {
  const AoidFlowIdle();
}

/// AOID is waiting for a factor.
final class AoidFlowAwaitingFactor extends AoidFlowState {
  const AoidFlowAwaitingFactor({
    required this.next,
    this.availableMethods = const [],
    this.webauthnChallenge,
    this.lastAttemptRejected = false,
  });

  /// Which factor to collect — `'password'`, `'mfa'`, `'webauthn'`.
  final String next;

  /// Factors the identity can satisfy. MAY BE EMPTY; render a picker only when
  /// it is not. The issuer refuses to emit this before a factor has succeeded
  /// because doing so makes the endpoint an enumeration oracle.
  final List<String> availableMethods;

  /// WebAuthn assertion options, verbatim.
  final Map<String, dynamic>? webauthnChallenge;

  /// The previous submission did not advance the ceremony: collect this factor
  /// again on the rotated handle.
  ///
  /// This flag is the ENTIRE signal, deliberately. AOID answers an unknown
  /// email, a wrong password, an account with no password credential and a
  /// locked account **byte-identically** (re-proved over real HTTP by
  /// deliberately lossy). There is no richer reason to surface, and manufacturing one —
  /// even in UI copy — reconstructs the account-existence oracle the issuer
  /// spent real effort removing.
  final bool lastAttemptRejected;
}

/// This factor cannot be completed in-app. Open a system browser.
///
/// NOT an error. Reached by social IdPs, PIV/CAC, and — on a
/// CORRECT password — any tenant on a `cryptographic` or
/// `physical` isolation tier.
final class AoidFlowRedirectRequired extends AoidFlowState {
  const AoidFlowRedirectRequired(this.result);

  /// The strategy contract's `AuthResult` variant. `reason` is TELEMETRY ONLY, never UI copy.
  final RedirectRequired result;
}

/// Terminal success: spend [authorizationCode] at `/oauth/token`.
final class AoidFlowComplete extends AoidFlowState {
  const AoidFlowComplete(this.authorizationCode);

  final String authorizationCode;
}

/// The ceremony is over and cannot be continued — but the USER can start a new
/// one. Replay, expiry, an unknown handle, a cross-tenant presentation and
/// The issuer's durable `MaxAttempts = 5` cap all land here, indistinguishably.
///
/// Deliberately NOT an exception: exhausting the attempt cap is an ordinary
/// end to a session, and "start again" is the whole of the correct UX. Do NOT
/// resubmit the old handle — it is consumed, and another presentation only
/// burns the successor.
final class AoidFlowRestartRequired extends AoidFlowState {
  const AoidFlowRestartRequired();
}

/// No authentication decision was reached: a socket error, a 500, or a replica
/// answering 503.
///
/// **The ceremony is not known to be over.** `AoidOidcAuthStrategy`
///.restoreSession swallows every non-200 as `null`, which signs the user out
/// on a blip; this state exists so that defect cannot be written here. On a
/// 503 specifically, the issuer's write gate fires BEFORE the service is called, so
/// the handle was never consumed and re-submitting the same factor is correct.
/// On a 500 or a dead socket the handle MAY have been consumed — a retry then
/// answers `invalid_session` and lands in [AoidFlowRestartRequired], which is
/// the honest outcome rather than a guess.
final class AoidFlowUnavailable extends AoidFlowState {
  const AoidFlowUnavailable(this.kind, {this.retryAfterSeconds});

  final AoidTransportFailureKind kind;

  /// From `Retry-After` on a 503. Honour it.
  final int? retryAfterSeconds;
}

/// AOID refused, and not because of the handle. `invalid_client` (the client
/// is unknown, has no `native_login_enabled`, or its origin is not on the
/// allowlist — all one answer by design) or `invalid_request`.
final class AoidFlowFailed extends AoidFlowState {
  const AoidFlowFailed(this.error);

  final AoidError error;
}

/// Drives the AOID native ceremony end to end.
///
/// Exposes step / next / availableMethods / outcome — **NEVER the credential**.
///
/// # D3
///
/// The plaintext password arrives as a PARAMETER, goes straight into the
/// request body, and is never assigned to a field, never logged, never placed
/// in an exception. There is deliberately no getter, callback or stream
/// through which app-owned Dart could read it back, and none may be added: a
/// "convenience" API letting an app supply or observe its own password field
/// defeats the whole objective. Adding one also defeats the issuer
/// containment guarantee, because the credential's only journey is
/// widget -> flow -> request body.
///
/// The PASSKEY path obeys the same rule. In [signInWithPasskey] the assertion
/// JSON is a LOCAL for its whole life: authenticator -> flow -> request body.
/// It is never assigned to a field, never logged, never placed in an
/// exception, and there is no getter for it — nor for the challenge's
/// `publicKey` map, which is passed to the authenticator and dropped.
///
/// Gate: `test/aoid/flow/aoid_native_flow_test.dart`, group "8 D3 source gate",
/// which strips comments and then scans for a credential getter, a credential
/// field, and a field holding the passkey assertion, with positive controls
/// proving every predicate can fire.
///
/// The widgets layer's sealed `AoidLoginForm` owns its own `TextEditingController` and
/// calls [submitPassword] directly. That call boundary is where D3's
/// containment is realised.
class AoidNativeFlow implements NativeCeremony {
  AoidNativeFlow({
    required AoidNativeClient client,
    required String clientId,
    required String tenantId,
    required String redirectUri,
  }) : _client = client,
       _clientId = clientId,
       _tenantId = tenantId,
       _redirectUri = redirectUri;

  final AoidNativeClient _client;
  final String _clientId;
  final String _tenantId;
  final String _redirectUri;

  /// The CURRENT handle. Private, and there is no accessor: nothing outside
  /// this class needs it, and every response replaces it. The issuer consumes the
  /// presented handle with a conditional UPDATE and inserts a successor, so a
  /// caller holding its own copy would present a dead value.
  String? _handle;

  AoidFlowState _state = const AoidFlowIdle();

  /// Where the ceremony stands. The login form renders from this and nothing else.
  AoidFlowState get state => _state;

  /// The terminal authorization code, once there is one. The deployment-mode layer's Mode A sink
  /// spends it at `/oauth/token`.
  String? get authorizationCode => _state is AoidFlowComplete
      ? (_state as AoidFlowComplete).authorizationCode
      : null;

  /// Whether a factor can still be submitted.
  bool get canSubmit => _handle != null && _state is! AoidFlowComplete;

  /// The arguments of the last [begin], so a passkey attempt that does not
  /// complete can start a fresh ceremony on its own (see [signInWithPasskey]).
  ///
  /// Only [begin]'s OWN arguments: the PKCE code CHALLENGE is public by
  /// design. The verifier never enters this class.
  _BeginArgs? _lastBegin;

  /// Whether the last START reply listed `webauthn_discoverable`. Remembered
  /// rather than re-read from [state]: a rejected password rotates the handle
  /// at the same stage and that reply carries no `available_methods`.
  bool _passkeyAdvertised = false;

  /// Whether the ceremony is at AOID's `started` stage — the only stage that
  /// accepts `webauthn_discoverable_challenge`.
  bool _atStarted = false;

  /// Whether a passkey sign-in can be offered right now: the start reply
  /// advertised `webauthn_discoverable`, the ceremony is still at the
  /// `started` stage, and there is a live handle.
  ///
  /// Survives a rejected password (same-stage rotation). Ends when a password
  /// advances the ceremony (MFA).
  bool get canUsePasskey => _passkeyAdvertised && _atStarted && canSubmit;

  /// Mint a ceremony. Call again after [AoidFlowRestartRequired].
  Future<void> begin({
    required String codeChallenge,
    List<String> scopes = const ['openid', 'profile', 'email'],
    String? nonce,
    AoidActiveTenantSlug? activeTenant,
    String? loginHint,
  }) async {
    _handle = null;
    _state = const AoidFlowIdle();
    _lastBegin = (
      codeChallenge: codeChallenge,
      scopes: scopes,
      nonce: nonce,
      activeTenant: activeTenant,
      loginHint: loginHint,
    );
    _passkeyAdvertised = false;
    _atStarted = false;
    await _step(
      () => _client.start(
        clientId: _clientId,
        tenantId: _tenantId,
        redirectUri: _redirectUri,
        codeChallenge: codeChallenge,
        scopes: scopes,
        nonce: nonce,
        activeTenant: activeTenant,
        loginHint: loginHint,
      ),
    );
    final started = _state;
    if (started is AoidFlowAwaitingFactor) {
      _atStarted = true;
      _passkeyAdvertised = started.availableMethods.contains(
        'webauthn_discoverable',
      );
    }
  }

  /// Submit the password factor.
  ///
  /// [password] is a LOCAL for its whole life: parameter -> request body. It
  /// is never stored. See the D3 note on this class.
  ///
  /// [email] is passed RAW. AOID normalises internally exactly as
  /// `PasswordLoginStart` does; normalising here too would key a DIFFERENT
  /// AC-7 rate-limit bucket than the factor actually consumes.
  Future<void> submitPassword({
    required String email,
    required String password,
  }) => _submit('password', {'email': email, 'password': password});

  /// Submit a TOTP code or a backup code — AOID accepts either on `otp`.
  Future<void> submitOtp(String otp) => _submit('totp', {'otp': otp});

  /// Submit a WebAuthn assertion. [responseJson] is the browser's own JSON,
  /// passed through UNTOUCHED: the assertion signature covers those exact
  /// bytes, so re-encoding invalidates it.
  Future<void> submitWebAuthn(
    String responseJson, {
    String method = 'webauthn',
  }) => _submit(method, {'webauthn_response': responseJson});

  /// Signs in with a discoverable passkey: no email, no password.
  ///
  /// SUPPORTED CALLER: the sealed `AoidLoginForm`. Deliberately NOT annotated
  /// `@internal` — `package:meta` is not a dependency of this package and the
  /// module avoids it. The parameter type [AoidPasskeyAuthenticator] is not
  /// exported, so app code cannot build a meaningful argument without a
  /// `src/` import anyway; and an app-supplied authenticator could only submit
  /// an assertion it produced itself, which [submitWebAuthn] already permits.
  ///
  /// Offer it only while [canUsePasskey] is true; otherwise this answers
  /// [AoidPasskeyOutcome.unavailable] without a request.
  ///
  /// # The server path
  ///
  /// AOID's stage table (`internal/nativelogin/stages.go`), the relevant rows:
  ///
  /// ```text
  /// started          -> password, webauthn_discoverable_challenge
  /// webauthn_pending -> webauthn, webauthn_discoverable
  /// ```
  ///
  /// 1. `method=webauthn_discoverable_challenge`, no factor field. AOID moves
  ///    to `webauthn_pending` and answers `next: "webauthn"` with a
  ///    `webauthn_challenge`.
  /// 2. The authenticator gets `webauthn_challenge['publicKey']` — the very map
  ///    the transport decoded, unmodified. These are the "server options" the
  ///    authenticator forwards (`rpId`, `challenge`, `userVerification`,
  ///    `timeout`) as the transport decoded them; they are NOT byte-identical
  ///    JSON and need not be. What must be byte-identical is the ASSERTION,
  ///    because its signature covers those exact bytes.
  /// 3. `method=webauthn_discoverable` with `webauthn_response` set to the
  ///    authenticator's string, untouched.
  ///
  /// # Why a restart
  ///
  /// There is NO edge from `webauthn_pending` back to `password`. Once the
  /// challenge is requested, a dismissed sheet, a missing passkey, an
  /// unassociated domain or a rejected assertion would leave the password
  /// field dead. So every one of those starts ONE fresh ceremony with the
  /// arguments of the last [begin] before returning, and the form stays
  /// usable without the app doing anything. If that restart itself fails,
  /// the answer is [AoidPasskeyOutcome.interrupted] and [state] says why.
  ///
  /// Reusing the same `code_challenge` for the fresh ceremony is safe: the
  /// abandoned one never minted an authorization code, and only one code can
  /// ever be exchanged with the app's single PKCE verifier — which never
  /// enters this class.
  ///
  /// # No retry
  ///
  /// Each `await` below is ONE request; nothing is retried — not the
  /// challenge, not the assertion, not the restart. AOID's `MaxAttempts = 5`
  /// is durable and carried across rotation, so a retry spends an attempt the
  /// user did not make.
  ///
  /// # Why `interrupted` does not restart
  ///
  /// [AoidPasskeyOutcome.interrupted] means [state] already describes what
  /// happened (network, 503, `invalid_session`, redirect, `invalid_client`).
  /// After a 503 in particular the replica refused BEFORE the service ran, so
  /// the handle is still valid and AOID is still at `started`: a restart
  /// would burn a ceremony the user can simply retry.
  ///
  /// # The assertion stays a local
  ///
  /// The assertion JSON is a local here, never stored, logged or exposed — see
  /// the credential-containment note on this class.
  Future<AoidPasskeyOutcome> signInWithPasskey(
    AoidPasskeyAuthenticator authenticator,
  ) async {
    if (!canUsePasskey) return AoidPasskeyOutcome.unavailable;

    await _submit('webauthn_discoverable_challenge', const <String, String>{});
    final challenged = _state;
    if (challenged is! AoidFlowAwaitingFactor ||
        challenged.lastAttemptRejected ||
        challenged.next != 'webauthn') {
      return AoidPasskeyOutcome.interrupted;
    }
    // AOID is now at webauthn_pending whatever the challenge looks like, so a
    // malformed one still needs a fresh ceremony for the password to work.
    final publicKey = challenged.webauthnChallenge?['publicKey'];
    if (publicKey is! Map<String, dynamic>) {
      return _restartThen(AoidPasskeyOutcome.failed);
    }

    final attempt = await authenticator.getAssertion(publicKey);
    switch (attempt) {
      case AoidPasskeyNotAsserted(:final reason):
        return _restartThen(switch (reason) {
          AoidPasskeyFailure.cancelled => AoidPasskeyOutcome.cancelled,
          AoidPasskeyFailure.notAssociated => AoidPasskeyOutcome.unavailable,
          AoidPasskeyFailure.unsupported => AoidPasskeyOutcome.unavailable,
          AoidPasskeyFailure.failed => AoidPasskeyOutcome.failed,
        });
      case AoidPasskeyAsserted(:final responseJson):
        await submitWebAuthn(responseJson, method: 'webauthn_discoverable');
    }

    return switch (_state) {
      AoidFlowComplete() => AoidPasskeyOutcome.completed,
      // AOID rotated at webauthn_pending: only another assertion is accepted
      // there, so the password needs a fresh ceremony.
      AoidFlowAwaitingFactor(lastAttemptRejected: true) => await _restartThen(
        AoidPasskeyOutcome.rejected,
      ),
      _ => AoidPasskeyOutcome.interrupted,
    };
  }

  /// Starts a fresh ceremony with the last [begin]'s arguments, then answers
  /// [outcome] — or [AoidPasskeyOutcome.interrupted] when the restart itself
  /// did not reach a usable step, so the form renders the state's notice.
  Future<AoidPasskeyOutcome> _restartThen(AoidPasskeyOutcome outcome) async {
    await _rebegin();
    return _state is AoidFlowAwaitingFactor
        ? outcome
        : AoidPasskeyOutcome.interrupted;
  }

  /// ONE `/oauth/native/start` replaying the last [begin]. Never retried.
  /// Does nothing if [begin] was never called.
  Future<void> _rebegin() async {
    final args = _lastBegin;
    if (args == null) return;
    await begin(
      codeChallenge: args.codeChallenge,
      scopes: args.scopes,
      nonce: args.nonce,
      activeTenant: args.activeTenant,
      loginHint: args.loginHint,
    );
  }

  Future<void> _submit(String method, Map<String, String> factorFields) async {
    final handle = _handle;
    if (handle == null) {
      _state = const AoidFlowRestartRequired();
      return;
    }
    // The handle is cleared BEFORE the call: the issuer consumes it server-side, so
    // it is dead the moment it leaves. Only a response can install a successor.
    _handle = null;
    await _step(
      () => _client.verify(
        authSession: handle,
        clientId: _clientId,
        tenantId: _tenantId,
        method: method,
        factorFields: factorFields,
      ),
      // A 503 refuses BEFORE the service is called, so the handle survives.
      handleOnUnavailable: handle,
    );
    // Only two outcomes leave AOID at the same stage: a rejected factor
    // (rotation with no `next`) and a 503 (the service never saw the request,
    // so the handle survived). Everything else moved the ceremony on or ended it.
    final after = _state;
    final sameStage =
        (after is AoidFlowAwaitingFactor && after.lastAttemptRejected) ||
        (after is AoidFlowUnavailable && _handle != null);
    if (!sameStage) _atStarted = false;
  }

  /// Runs ONE request and folds the outcome into [_state].
  ///
  /// There is deliberately NO retry here. The issuer's `MaxAttempts = 5` is durable
  /// and carried forward on rotation, so an automatic retry burns the
  /// successor and can destroy a ceremony the user could still have completed.
  Future<void> _step(
    Future<AoidNativeResponse> Function() send, {
    String? handleOnUnavailable,
  }) async {
    try {
      final response = await send();
      switch (response) {
        case AoidNativeCode():
          _state = AoidFlowComplete(response.authorizationCode);
        case AoidNativeContinue():
          _handle = response.authSession;
          _state = AoidFlowAwaitingFactor(
            // An empty `next` means the factor did not advance the ceremony;
            // the step to collect is therefore unchanged.
            next: response.advanced ? response.next : _currentStep,
            availableMethods: response.availableMethods,
            webauthnChallenge: response.webauthnChallenge,
            lastAttemptRejected: !response.advanced,
          );
        case AoidNativeRedirect():
          _state = AoidFlowRedirectRequired(response.result);
      }
    } on AoidError catch (e) {
      // invalid_session covers replay, expiry, unknown handle, cross-tenant
      // AND attempt-cap exhaustion — one answer, by design. All of them mean
      // the same thing to a user: start again.
      _state = e.code == AoidErrorCode.invalidSession
          ? const AoidFlowRestartRequired()
          : AoidFlowFailed(e);
    } on AoidTransportError catch (e) {
      if (e.kind == AoidTransportFailureKind.unavailable &&
          handleOnUnavailable != null) {
        _handle = handleOnUnavailable;
      }
      _state = AoidFlowUnavailable(
        e.kind,
        retryAfterSeconds: e.retryAfterSeconds,
      );
    }
  }

  /// The step currently being collected, so a rejected factor re-prompts the
  /// same one rather than blanking the form.
  String get _currentStep => switch (_state) {
    AoidFlowAwaitingFactor(next: final n) => n,
    _ => '',
  };
}
