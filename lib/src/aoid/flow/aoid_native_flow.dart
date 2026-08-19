// The AOID native ceremony state machine — the CONTROLLER the spec sealed
// AoidLoginForm drives.
//
// RIVERPOD-FREE and Flutter-free: reachable from lib/aoid.dart.

import '../../auth/auth_strategy.dart' show RedirectRequired;
import '../claims/tenant_ref.dart' show AoidActiveTenantSlug;
import '../transport/aoid_error.dart';
import '../transport/aoid_native_client.dart';

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
  /// it is not. the spec refuses to emit this before a factor has succeeded
  /// because doing so makes the endpoint an enumeration oracle.
  final List<String> availableMethods;

  /// WebAuthn assertion options, verbatim.
  final Map<String, dynamic>? webauthnChallenge;

  /// The previous submission did not advance the ceremony: collect this factor
  /// again on the rotated handle.
  ///
  /// This flag is the ENTIRE signal, deliberately. AOID answers an unknown
  /// email, a wrong password, an account with no password credential and a
  /// locked account **byte-identically** (the spec, re-proved over real HTTP by
  /// the spec). There is no richer reason to surface, and manufacturing one —
  /// even in UI copy — reconstructs the account-existence oracle the issuer
  /// spent a the spec removing.
  final bool lastAttemptRejected;
}

/// This factor cannot be completed in-app. Open a system browser.
///
/// NOT an error. Reached by social IdPs, PIV/CAC, and — on a
/// CORRECT password — any tenant on a `cryptographic` or
/// `physical` isolation tier.
final class AoidFlowRedirectRequired extends AoidFlowState {
  const AoidFlowRedirectRequired(this.result);

  /// the spec `AuthResult` variant. `reason` is TELEMETRY ONLY, never UI copy.
  final RedirectRequired result;
}

/// Terminal success: spend [authorizationCode] at `/oauth/token`.
final class AoidFlowComplete extends AoidFlowState {
  const AoidFlowComplete(this.authorizationCode);

  final String authorizationCode;
}

/// The ceremony is over and cannot be continued — but the USER can start a new
/// one. Replay, expiry, an unknown handle, a cross-tenant presentation and
/// the spec durable `MaxAttempts = 5` cap all land here, indistinguishably.
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
/// 503 specifically, the spec write gate fires BEFORE the service is called, so
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
/// Gate: `test/aoid/flow/aoid_native_flow_test.dart`, group "8 D3 source gate",
/// which strips comments and then scans for a credential getter or a
/// credential field, with a positive control proving both predicates can fire.
///
/// the spec sealed `AoidLoginForm` owns its own `TextEditingController` and
/// calls [submitPassword] directly. That call boundary is where D3's
/// containment is realised.
class AoidNativeFlow {
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
  /// this class needs it, and every response replaces it. the spec consumes the
  /// presented handle with a conditional UPDATE and inserts a successor, so a
  /// caller holding its own copy would present a dead value.
  String? _handle;

  AoidFlowState _state = const AoidFlowIdle();

  /// Where the ceremony stands. the spec renders from this and nothing else.
  AoidFlowState get state => _state;

  /// The terminal authorization code, once there is one. the spec Mode A sink
  /// spends it at `/oauth/token`.
  String? get authorizationCode => _state is AoidFlowComplete
      ? (_state as AoidFlowComplete).authorizationCode
      : null;

  /// Whether a factor can still be submitted.
  bool get canSubmit => _handle != null && _state is! AoidFlowComplete;

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

  Future<void> _submit(String method, Map<String, String> factorFields) async {
    final handle = _handle;
    if (handle == null) {
      _state = const AoidFlowRestartRequired();
      return;
    }
    // The handle is cleared BEFORE the call: the spec consumes it server-side, so
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
  }

  /// Runs ONE request and folds the outcome into [_state].
  ///
  /// There is deliberately NO retry here. the spec `MaxAttempts = 5` is durable
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
