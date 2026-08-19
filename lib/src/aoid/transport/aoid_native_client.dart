// The client half of the issuer /oauth/native/* contract (SDK-02).
//
// FORM IN, JSON OUT, ZERO CUSTOM REQUEST HEADERS.
//
// RIVERPOD-FREE and Flutter-free. It imports lib/src/auth/auth_strategy.dart
// for RedirectRequired; that file imports only platform_models.dart, which
// imports nothing, so lib/aoid.dart's closure stays clean (the strategy contract verified this
// and handed the note to this work).

import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import '../../auth/auth_strategy.dart' show RedirectRequired;
import '../claims/tenant_ref.dart' show AoidActiveTenantSlug;
import 'aoid_endpoints.dart';
import 'aoid_error.dart';

/// What one step of the native ceremony produced.
///
/// There are exactly three NON-failure outcomes. Everything else throws
/// [AoidError] (an authentication refusal) or [AoidTransportError] (no
/// authentication decision was reached at all).
sealed class AoidNativeResponse {
  const AoidNativeResponse();
}

/// TERMINAL. The ceremony minted the authorization code.
///
/// Wire: `200 {"authorization_code":"…"}` — **exactly one key**.
///
/// NOTE THE SPELLING. The key is `authorization_code`, not `code`. The issuer's
/// `nativeSuccessBody` has a single field and its comment explains why a spare
/// `auth_session` cannot ride along: it would leave a live handle after the
/// ceremony ended.
final class AoidNativeCode extends AoidNativeResponse {
  const AoidNativeCode(this.authorizationCode);

  final String authorizationCode;
}

/// The ceremony CONTINUES, carrying a handle that has ROTATED.
///
/// Two wire shapes land here, and telling them apart is the whole point:
///
/// * `200 {"auth_session","next","available_methods"}` — the `start` response.
/// * `401 {"error":"insufficient_authorization","auth_session":"<NEW>", …}` —
///   every intermediate `verify`. The issuer's `Verify` returns BOTH a response
///   and a non-nil error mid-ceremony, and both arrive together. Treating
///   that 401 as a failure throws away the successor handle and breaks the
///   ceremony at step two.
///
/// [advanced] distinguishes "the factor succeeded, here is the next step" from
/// "the factor did not succeed, present the same step again". That is the ONLY
/// signal AOID gives, and deliberately so: the issuer proved a wrong password and a
/// correct password needing MFA share their status, their code and every
/// header, and differ ONLY in `next` / `available_methods`. Do not try to
/// recover a richer reason — there isn't one, and inventing one rebuilds the
/// enumeration oracle.
final class AoidNativeContinue extends AoidNativeResponse {
  const AoidNativeContinue({
    required this.authSession,
    this.next = '',
    this.availableMethods = const [],
    this.webauthnChallenge,
  });

  /// The ROTATED handle. **Present THIS on the next step, never the previous
  /// one.** The issuer consumes the presented handle with a conditional UPDATE and
  /// inserts a successor, so re-presenting the old value returns zero rows and
  /// answers `invalid_session` — which looks exactly like a server bug.
  final String authSession;

  /// Which factor AOID wants next — `'password'`, `'mfa'`, `'webauthn'`.
  /// EMPTY when the submitted factor did not advance the ceremony.
  final String next;

  /// Factors the identity can satisfy for [next]. May be EMPTY: the issuer refuses
  /// to emit `available_methods` before a factor has succeeded, because doing
  /// so makes the endpoint an enumeration oracle. Render a picker only when it
  /// is non-empty; an empty list is correct, not an error.
  final List<String> availableMethods;

  /// WebAuthn assertion options, verbatim. Passed through untouched — the issuer
  /// proved re-encoding reorders keys and re-escapes unicode, and the
  /// assertion signature covers those bytes.
  final Map<String, dynamic>? webauthnChallenge;

  /// Whether the submitted factor moved the ceremony forward.
  bool get advanced => next.isNotEmpty;
}

/// Fall back to the hosted browser flow. **NOT a failure**.
///
/// Wire: `400 {"error":"redirect_to_web","error_description":"…",
/// "authorization_url":"…"}`. Reached by social IdPs, PIV/CAC, and — on a
/// perfectly CORRECT password — any tenant whose isolation tier is
/// `cryptographic` or `physical`.
/// Rendering it as a login failure is a real bug against a real enterprise
/// tenant.
final class AoidNativeRedirect extends AoidNativeResponse {
  const AoidNativeRedirect(this.result);

  /// The `AuthResult` variant, ready for `AuthNotifier` and for the redirect
  /// browser hop. Its `reason` is TELEMETRY ONLY — never UI copy.
  final RedirectRequired result;
}

/// Speaks the issuer `/oauth/native/{start,verify}` contract.
///
/// Uses `package:http`, matching `AoidOidcAuthStrategy` and the whole existing
/// fixture suite. **Do not introduce `dio` here** even though it is in the
/// pubspec: mixing transports forks `FakeAoidEndpoint`, which the native and
/// The redirect flow all extend.
class AoidNativeClient {
  const AoidNativeClient({
    required AoidEndpoints endpoints,
    required http.Client httpClient,
  }) : _endpoints = endpoints,
       _http = httpClient;

  final AoidEndpoints _endpoints;
  final http.Client _http;

  /// THE header map. One entry, forever.
  ///
  /// This is the entire CORS contract. The issuer built a PER-CLIENT origin
  /// allowlist that resolves `client_id` from the request BODY, which only
  /// works because these are CORS **simple requests**: a preflight is an
  /// `OPTIONS` with no body, so `client_id` would be unresolvable and the
  /// allowlist would stop working. `Content-Type` with a form media type is
  /// CORS-safelisted; ANY other header is not.
  ///
  /// Verified live against `auth.aocyber.ai` on 2026-08-01: preflight answers
  /// `204` with `access-control-allow-origin: *` and no
  /// `Access-Control-Allow-Credentials`.
  ///
  /// So: no `X-AOID-Tenant`, no `X-Requested-With`, no bearer, no correlation
  /// id. `tenant_id` and `client_id` go in the FORM BODY. Do not "tidy" a
  /// field into a header. Server-side this is enforced by the issuer
  /// `TestNativeHandlersReadNoCustomRequestHeader`; client-side by
  /// test-list item 2, which asserts this map's KEY SET.
  ///
  /// MEASURED, not assumed: with `http: ^1.2.0` the header map that reaches
  /// the transport is exactly `{content-type: application/x-www-form-urlencoded}`
  /// — no charset parameter is appended, and no other application header is
  /// added. (`dart:io` adds `content-length` / `host` / `accept-encoding` at
  /// the socket layer, and a browser adds its own; all are CORS-safelisted or
  /// forbidden header names the user agent controls, so none of them
  /// preflights. On web, `BrowserClient` sends only what is in this map.)
  /// The issuer's `isFormContent` splits on `;` before comparing, so a charset
  /// parameter would be tolerated too — but none is sent.
  static const Map<String, String> _formHeaders = {
    'content-type': 'application/x-www-form-urlencoded',
  };

  /// Step 1: mint a ceremony.
  ///
  /// [redirectUri] is REQUIRED. AOID deliberately deviates from
  /// draft-ietf-oauth-first-party-apps-03 here so `IssueAuthorizationCode` is
  /// reused untouched and its exact-match property is preserved.
  Future<AoidNativeResponse> start({
    required String clientId,
    required String tenantId,
    required String redirectUri,
    required String codeChallenge,
    String codeChallengeMethod = 'S256',
    List<String> scopes = const [],
    String? nonce,
    AoidActiveTenantSlug? activeTenant,
    String? loginHint,
  }) {
    return _post(_endpoints.nativeStart, {
      'client_id': clientId,
      // FORM FIELD, never a header. See _formHeaders.
      'tenant_id': tenantId,
      'redirect_uri': redirectUri,
      'code_challenge': codeChallenge,
      'code_challenge_method': codeChallengeMethod,
      // RFC 6749 §3.3 — SPACE-delimited. The issuer splits on space.
      if (scopes.isNotEmpty) 'scope': scopes.join(' '),
      if (nonce != null && nonce.isNotEmpty) 'nonce': nonce,
      // The ACTIVE tenant SLUG, on `tenant`, mirroring /oauth/authorize.
      // Confusingly adjacent to `tenant_id` (a UUID) — that is D5's trap, and
      // the types keep them apart.
      if (activeTenant != null) 'tenant': activeTenant.slug,
      if (loginHint != null && loginHint.isNotEmpty) 'login_hint': loginHint,
    });
  }

  /// Step 2..N: present ONE factor.
  ///
  /// [factorFields] carries the factor's own inputs — `email` + `password`,
  /// `otp`, or `webauthn_response`. They are written straight into the request
  /// body and are never retained, logged, or placed in an exception.
  ///
  /// **Never retry this call automatically on [AoidErrorCode.invalidSession].**
  /// The presented handle is already consumed; a retry burns the successor and
  /// walks into the issuer's durable `MaxAttempts = 5` cap, destroying a ceremony
  /// that was still recoverable.
  Future<AoidNativeResponse> verify({
    required String authSession,
    required String clientId,
    required String tenantId,
    required String method,
    Map<String, String> factorFields = const {},
  }) {
    return _post(_endpoints.nativeVerify, {
      'auth_session': authSession,
      'client_id': clientId,
      'tenant_id': tenantId,
      'method': method,
      ...factorFields,
    });
  }

  Future<AoidNativeResponse> _post(Uri url, Map<String, String> fields) async {
    final http.Response response;
    try {
      response = await _http.post(url, headers: _formHeaders, body: fields);
    } on http.ClientException {
      throw const AoidTransportError(AoidTransportFailureKind.network);
    } on SocketException {
      throw const AoidTransportError(AoidTransportFailureKind.network);
    }
    return _interpret(response);
  }

  AoidNativeResponse _interpret(http.Response response) {
    // 503 is checked BEFORE the body: a replica refuses the write before the
    // service is ever called, so there is no authentication decision
    // in there to read.
    if (response.statusCode == 503) {
      throw AoidTransportError(
        AoidTransportFailureKind.unavailable,
        statusCode: 503,
        retryAfterSeconds: int.tryParse(
          response.headers['retry-after']?.trim() ?? '',
        ),
      );
    }

    final Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('not a JSON object');
      }
      body = decoded;
    } on FormatException {
      throw AoidTransportError(
        AoidTransportFailureKind.malformed,
        statusCode: response.statusCode,
      );
    }

    final error = body['error'];

    // Terminal. 200 with exactly one key.
    final authorizationCode = body['authorization_code'];
    if (authorizationCode is String && authorizationCode.isNotEmpty) {
      return AoidNativeCode(authorizationCode);
    }

    if (error == 'redirect_to_web') {
      final raw = body['authorization_url'];
      final url = raw is String ? Uri.tryParse(raw) : null;
      // Deferred item 1, owned here: RedirectRequired cannot refuse
      // an empty or relative Uri, and one would park AuthNotifier in
      // `refreshing` with nothing to open and no error ever surfacing. Refuse
      // it here instead.
      if (url == null || !url.hasScheme || !url.hasAuthority) {
        throw const AoidError(AoidErrorCode.invalidRequest);
      }
      return AoidNativeRedirect(
        // `reason` is TELEMETRY ONLY. It carries the wire code and nothing
        // that could become UI copy — the issuer hides WHY on purpose.
        RedirectRequired(url, reason: 'redirect_to_web'),
      );
    }

    // A successor handle means the ceremony is alive, whatever the status.
    //
    // This is the branch the whole client turns on. `start` answers 200 with
    // one; every intermediate `verify` answers 401 `insufficient_authorization`
    // with one — INCLUDING a verify whose factor was rejected, which differs
    // from an accepted one only by the absence of `next`. Reading the status
    // alone, or the presence of `error` alone, loses the rotated handle and
    // ends a recoverable ceremony.
    final authSession = body['auth_session'];
    if (authSession is String && authSession.isNotEmpty) {
      final challenge = body['webauthn_challenge'];
      return AoidNativeContinue(
        authSession: authSession,
        next: body['next'] is String ? body['next'] as String : '',
        availableMethods: _stringList(body['available_methods']),
        webauthnChallenge: challenge is Map<String, dynamic> ? challenge : null,
      );
    }

    if (error is String) {
      final code = _codeFor(error);
      if (code != null) throw AoidError(code);
    }

    // 500 server_error, and anything else the contract does not define. NOT an
    // authentication decision — see AoidTransportError's doc comment.
    throw AoidTransportError(
      response.statusCode >= 500
          ? AoidTransportFailureKind.server
          : AoidTransportFailureKind.malformed,
      statusCode: response.statusCode,
    );
  }

  static AoidErrorCode? _codeFor(String wire) => switch (wire) {
    'invalid_request' => AoidErrorCode.invalidRequest,
    'invalid_client' => AoidErrorCode.invalidClient,
    'invalid_session' => AoidErrorCode.invalidSession,
    'insufficient_authorization' => AoidErrorCode.insufficientAuthorization,
    // redirect_to_web is handled above as a RESULT and must never reach here.
    _ => null,
  };

  static List<String> _stringList(Object? raw) => raw is List
      ? raw.whereType<String>().toList(growable: false)
      : const <String>[];
}
