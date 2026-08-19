// MODE A's SEAM — where the authorization code goes when the client is not
// allowed to spend it.
//
// RIVERPOD-FREE BY CONSTRUCTION (see storage/aoid_token_store.dart's header).

import '../aoid_session.dart';

/// Mode A. The SDK obtains an authorization code and hands it to the
/// CONSUMING APP'S OWN backend, which holds the client secret, performs the
/// exchange with AOID, and sets an httpOnly `SameSite` cookie. The refresh
/// token never reaches the browser — the design notes' ranked-first posture.
///
/// ## The `code_verifier` IS sent to the app's own backend
///
/// That looks alarming and it is correct. PKCE binds the code to the client
/// instance that started the ceremony, and in Mode A that instance spans
/// app-frontend **and** app-backend. Without the verifier the backend's
/// exchange fails.
///
/// The verifier is NOT a credential in the confidential-client sense and it
/// **MUST NOT be confused with the client secret**, which never leaves the
/// app's backend. Do not "protect" the verifier in secure storage — that is how
/// the web-storage exposure the token store removed comes back. Do not remove it
/// thinking it is a leak. Either change breaks Mode A.
///
/// ## Only ONE party may spend the code
///
/// The authorization code is single-use. In Mode A the spender is the app's
/// backend; in Modes B and C it is the client. An implementation that also
/// exchanges at AOID burns the code, and the backend's exchange then fails with
/// an opaque `invalid_grant` that reads as a server fault.
///
/// Implementations MUST NOT auto-retry [submit]. A retry re-presents a code
/// that may already have been spent successfully.
abstract class AoidCodeSink {
  /// Hands [code] and [codeVerifier] to the app's backend and returns the
  /// resulting cookie-bound session.
  ///
  /// [redirectUri] is included when the authorize request carried one; AOID
  /// requires it to match at exchange time.
  ///
  /// Throws [AoidBffExchangeError] — never `AoidError`. A broken backend is not
  /// a rejected credential.
  Future<AoidSession> submit({
    required String code,
    required String codeVerifier,
    String? redirectUri,
  });
}

/// Why a Mode A exchange did not produce a session.
///
/// Every value here describes the **consuming app's own backend**, not AOID.
/// That distinction is the whole point of the type: an app outage and a wrong
/// password are different events, with different owners and different
/// remedies, and collapsing them makes every outage look like a credential
/// problem to users and to support.
enum AoidBffFailureKind {
  /// The socket died, DNS failed, TLS failed — the app's backend was never
  /// reached.
  unreachable,

  /// The app's backend answered 5xx. It is up, and broken.
  backendError,

  /// The app's backend answered 4xx. It reached a decision and refused —
  /// including refusing a REPLAYED authorization code. Still not an AOID
  /// authentication outcome: the client cannot see AOID's decision in Mode A,
  /// because it never spoke to AOID.
  backendRefused,

  /// The exchange succeeded but the session cookie was not `HttpOnly` +
  /// `SameSite`.
  ///
  /// **Only detectable where `Set-Cookie` is visible** — native and tests. On
  /// web an httpOnly cookie is invisible to JS by definition, so this can never
  /// fire there. See [AoidBffExchangeError].
  insecureSessionCookie,
}

/// A Mode A exchange failure, against the **app's own backend**.
///
/// Deliberately NOT an `AoidError` and NOT an `AoidTransportError`:
///
/// | type | the failing system |
/// |---|---|
/// | `AoidError` | AOID reached an authentication decision and refused |
/// | `AoidTransportError` | AOID itself was unreachable or broken |
/// | [AoidBffExchangeError] | **the consuming app's own backend** |
///
/// Three systems, three types. A caller that only catches `AoidError` will not
/// accidentally render an app outage as "wrong password".
///
/// FIXED VOCABULARY, following `aoid_error.dart`. The backend's own response
/// body is never reflected into a message: a backend that echoes a stack trace,
/// the `code_verifier`, or its own client secret would otherwise carry all of
/// it into every log sink the app has.
class AoidBffExchangeError implements Exception {
  const AoidBffExchangeError(this.kind, {this.statusCode});

  final AoidBffFailureKind kind;

  /// The HTTP status the app's backend returned, or `null` when the request
  /// never produced a response.
  final int? statusCode;

  /// FIXED VOCABULARY. Never contains request input or response text.
  String get message => switch (kind) {
    AoidBffFailureKind.unreachable =>
      "could not reach this application's backend",
    AoidBffFailureKind.backendError =>
      "this application's backend had a problem completing sign-in",
    AoidBffFailureKind.backendRefused =>
      "this application's backend did not accept the sign-in",
    AoidBffFailureKind.insecureSessionCookie =>
      "this application's backend set a session cookie without HttpOnly and "
          'SameSite',
  };

  @override
  String toString() => 'AoidBffExchangeError(${kind.name}): $message';
}
