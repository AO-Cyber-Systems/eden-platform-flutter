// R-ACL-03 fake AOID `/oauth/*` endpoint — an `http.Client` (via
// `package:http/testing.dart`'s `MockClient`) that reproduces the AOID
// frozen contract §1 mechanics closely enough to drive
// `AoidOidcAuthStrategy` end-to-end without a live AOID instance.
//
// Hand-built per the global TDD playbook habit #4 — no LLM-generated
// external-API test data.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'aoid_fixtures.dart';

// ---------------------------------------------------------------------------
// the spec — the /oauth/native/* ceremony fixtures.
//
// EVERY value below is a hand-written literal (no_llm_test_data). the spec
// and the spec all extend THIS fixture; a second fake would guarantee drift.
// ---------------------------------------------------------------------------

/// Issuer origin used by the native-ceremony tests.
const kFakeAoidIssuer = 'https://auth.fake-aoid.test';

/// The OAuth `client_id` string (not the `oauth_clients.id` UUID — the spec
/// Binding carries both and only the UUID is stored).
const kFakeNativeClientId = 'aodex-web';

/// Tenant A — the tenant every ceremony below is STARTED under.
const kFakeTenantA = '11111111-1111-4111-8111-111111111111';

/// Tenant B — a DIFFERENT tenant, used only to present a cross-tenant
/// continuation. It must be refused indistinguishably from a replay.
const kFakeTenantB = '22222222-2222-4222-8222-222222222222';

const kFakeRedirectUri = 'https://app.fake-aoid.test/callback';
const kFakeCodeChallenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';

/// The handle `/oauth/native/start` mints. Successors are
/// `native-handle-alpha-0002`, `-0003`, … in order.
const kFakeHandle1 = 'native-handle-alpha-0001';

/// Where a `redirect_to_web` outcome sends the system browser.
const kFakeAuthorizationUrl =
    'https://auth.fake-aoid.test/oauth/authorize?response_type=code'
    '&client_id=aodex-web&redirect_uri=https%3A%2F%2Fapp.fake-aoid.test'
    '%2Fcallback&code_challenge_method=S256';

/// One scripted outcome for a single `/oauth/native/verify` call.
///
/// The fixture is SCRIPTED rather than clever: a test states the ceremony it
/// wants and the fake replays it. That keeps every branch reachable without
/// the fake growing an authentication implementation of its own.
sealed class FakeNativeStep {
  const FakeNativeStep();
}

/// The factor SUCCEEDED and the ceremony advances.
///
/// Wire:
///
/// ```
/// 401 {"error":"insufficient_authorization",
///      "error_description":"additional authorization required",
///      "auth_session":"THE-ROTATED-ONE","next":"mfa",
///      "available_methods":["totp","backup_code"]}
/// ```
class FakeNativeAdvance extends FakeNativeStep {
  const FakeNativeAdvance({
    required this.next,
    this.availableMethods = const [],
    this.webauthnChallenge,
  });

  final String next;
  final List<String> availableMethods;

  /// Raw JSON, passed through untouched (the spec mutation 13).
  final String? webauthnChallenge;
}

/// The factor FAILED but the ceremony survives: the spec `Consume` burns the
/// presented handle and `Rotate` issues a successor carrying the attempt
/// count. The response is byte-identical to [FakeNativeAdvance] except that
/// `next` and `available_methods` are absent — the spec
/// `a_wrong_password_and_a_correct_password_needing_MFA_share_code_and_status`
/// pins that the asymmetry lives ONLY there, never in the code or the status.
class FakeNativeReject extends FakeNativeStep {
  const FakeNativeReject();
}

/// Terminal: `200 {"authorization_code":"…"}` and NOTHING else.
class FakeNativeTerminal extends FakeNativeStep {
  const FakeNativeTerminal(this.authorizationCode);

  final String authorizationCode;
}

/// `400 {"error":"redirect_to_web","error_description":"…",
/// "authorization_url":"…"}` — a NORMAL outcome (social IdP, PIV, or the spec
/// a restrictive tenancy tier), not a failure.
class FakeNativeRedirect extends FakeNativeStep {
  const FakeNativeRedirect({this.authorizationUrl = kFakeAuthorizationUrl});

  /// Set to `''` to model the malformed case handed to this layer:
  /// a `redirect_to_web` whose `authorization_url` is unusable.
  final String authorizationUrl;
}

/// the spec `MaxAttempts = 5` exhausted: the ceremony is destroyed and NO
/// successor handle comes back. Indistinguishable from replay / expiry /
/// unknown-handle / cross-tenant, by design.
class FakeNativeAttemptCapExceeded extends FakeNativeStep {
  const FakeNativeAttemptCapExceeded();
}

/// An arbitrary opaque error from the spec taxonomy, e.g. `invalid_client`.
class FakeNativeErrorStep extends FakeNativeStep {
  const FakeNativeErrorStep({
    required this.code,
    required this.description,
    required this.status,
  });

  final String code;
  final String description;
  final int status;
}

/// A replica refusing the write: `503 temporarily_unavailable` with
/// `Retry-After` and — deliberately — no ACAO.
class FakeNativeUnavailable extends FakeNativeStep {
  const FakeNativeUnavailable({this.retryAfterSeconds = 30});

  final int retryAfterSeconds;
}

/// `500 {"error":"server_error","error_description":"internal error"}`.
class FakeNativeServerError extends FakeNativeStep {
  const FakeNativeServerError();
}

/// The socket dies. NOT an authentication outcome.
class FakeNativeNetworkFailure extends FakeNativeStep {
  const FakeNativeNetworkFailure();
}

/// A single recorded native request: what the client actually put on the wire.
class RecordedNativeRequest {
  RecordedNativeRequest({
    required this.path,
    required this.headers,
    required this.rawBody,
    required this.fields,
  });

  final String path;

  /// The header map as `package:http` handed it to the transport. Item 2 of
  /// the test list asserts on its KEY SET — that is the whole CORS
  /// simple-request contract.
  final Map<String, String> headers;

  final String rawBody;

  /// [rawBody] parsed as `application/x-www-form-urlencoded`.
  final Map<String, String> fields;
}

/// A fake AOID OAuth endpoint. Exposes an [http.Client] (`.client`) suitable
/// for injection into `AoidOidcAuthStrategy`'s `httpClient` parameter.
class FakeAoidEndpoint {
  FakeAoidEndpoint({required this.issuer});

  final String issuer;

  /// Every request the fake has handled, in order — for assertions like
  /// "no token POST fired" (`capturedRequests.isEmpty`).
  final List<http.Request> capturedRequests = [];

  int? _nextTokenStatus;
  bool _revokeShouldFailNetwork = false;

  /// Overrides the token response for auth-code exchanges. Defaults to the
  /// fixture access/refresh token pair when unset.
  String? tokenAccessToken;
  String? tokenRefreshToken;

  /// Overrides the `id_token` in the token response. Defaults to the fixture
  /// id_token when unset (and [omitIdToken] is false).
  String? tokenIdToken;

  /// When true, the token response OMITS the `id_token` key entirely --
  /// simulating a legacy/non-OIDC AOID response so the strategy's
  /// backward-compat (id_token absent => session.idToken == null) can be
  /// exercised.
  bool omitIdToken = false;

  /// Make the NEXT `/oauth/token` call respond with [status] (a JSON AOID
  /// error body) instead of 200. One-shot — resets after being consumed.
  void respondNextTokenCallWith(int status) {
    _nextTokenStatus = status;
  }

  /// Make `/oauth/revoke` throw (simulating a network failure) instead of
  /// responding 200.
  void simulateRevokeNetworkFailure() {
    _revokeShouldFailNetwork = true;
  }

  // -------------------------------------------------------------------------
  // the spec — /oauth/native/{start,verify}
  // -------------------------------------------------------------------------

  /// Every native request the fake handled, in order — path, header map, raw
  /// body and parsed form fields.
  final List<RecordedNativeRequest> nativeRequests = [];

  /// Every `auth_session` the fake has minted, in order. `[0]` is what `start`
  /// returned. A test asserts ROTATION against this plus the recorded request
  /// bodies (test-list item 6).
  final List<String> mintedNativeHandles = [];

  final List<FakeNativeStep> _nativeScript = [];

  String? _liveNativeHandle;
  String? _nativeTenantId;
  String? _nativeClientId;
  bool _nativeExpired = false;
  int _handleSeq = 0;

  /// State the `start` response reports. the spec makes both STATIC — emitting a
  /// per-identity list before a factor succeeds would make the endpoint an
  /// enumeration oracle.
  String startNext = 'password';
  List<String>? startAvailableMethods = const [
    'password',
    'webauthn_discoverable',
  ];

  /// Script what each successive `/oauth/native/verify` call does.
  void scriptNativeCeremony(List<FakeNativeStep> steps) {
    _nativeScript
      ..clear()
      ..addAll(steps);
  }

  /// Kill the ceremony's absolute deadline (the spec: `ceremony_expires_at` is
  /// never extended on rotation).
  void expireNativeCeremony() {
    _nativeExpired = true;
  }

  /// The fake endpoint's [http.Client]. Routes `POST {issuer}/oauth/token`,
  /// `POST {issuer}/oauth/revoke`, `POST {issuer}/oauth/native/start` and
  /// `POST {issuer}/oauth/native/verify`; anything else is 404.
  http.Client get client => MockClient((request) async {
        capturedRequests.add(request);

        if (request.url.path.endsWith('/oauth/native/start')) {
          return _handleNative(request, isStart: true);
        }
        if (request.url.path.endsWith('/oauth/native/verify')) {
          return _handleNative(request, isStart: false);
        }
        if (request.method == 'POST' && request.url.path.endsWith('/oauth/token')) {
          return _handleToken(request);
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/oauth/revoke')) {
          return _handleRevoke(request);
        }
        return http.Response('{"error":"not_found"}', 404);
      });

  // The ONE function that renders invalid_session. Replay, expiry, unknown
  // handle, cross-tenant presentation, cross-client presentation and attempt-
  // cap exhaustion ALL go through it, so byte-identity is structural rather
  // than six coincidentally-equal literals. the spec folds them together on
  // purpose; a fixture that distinguished them would make the client's own
  // lossiness test pass vacuously.
  http.Response _nativeInvalidSession() => _nativeJson(400, {
        'error': 'invalid_session',
        'error_description': 'invalid or expired auth_session',
      });

  http.Response _nativeJson(
    int status,
    Map<String, dynamic> body, {
    Map<String, String> extraHeaders = const {},
  }) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {
          // the spec writeNativeJSON header discipline.
          'content-type': 'application/json',
          'cache-control': 'no-store',
          'pragma': 'no-cache',
          ...extraHeaders,
        },
      );

  String _mintNativeHandle() {
    _handleSeq += 1;
    final handle = 'native-handle-alpha-${_handleSeq.toString().padLeft(4, '0')}';
    mintedNativeHandles.add(handle);
    return handle;
  }

  Future<http.Response> _handleNative(
    http.Request request, {
    required bool isStart,
  }) async {
    final fields = request.body.isEmpty
        ? <String, String>{}
        : Uri.splitQueryString(request.body);
    nativeRequests.add(RecordedNativeRequest(
      path: request.url.path,
      headers: Map<String, String>.from(request.headers),
      rawBody: request.body,
      fields: fields,
    ));

    if (request.method != 'POST') {
      return _nativeJson(405, {
        'error': 'invalid_request',
        'error_description': 'method not allowed',
      });
    }

    // the spec reuses isFormContent, whose comment reads "NEVER accept JSON
    // request bodies on OAuth endpoints." It splits on ';' so a charset
    // parameter is fine — which matters, because package:http appends one.
    final contentType = request.headers['content-type'] ?? '';
    final mediaType = contentType.split(';').first.trim().toLowerCase();
    if (mediaType.isNotEmpty && mediaType != 'application/x-www-form-urlencoded') {
      return _nativeJson(400, {
        'error': 'invalid_request',
        'error_description':
            'Content-Type must be application/x-www-form-urlencoded',
      });
    }

    return isStart ? _handleNativeStart(fields) : _handleNativeVerify(fields);
  }

  Future<http.Response> _handleNativeStart(Map<String, String> fields) async {
    for (final required in const [
      'client_id',
      'tenant_id',
      'redirect_uri',
      'code_challenge',
    ]) {
      if ((fields[required] ?? '').isEmpty) {
        return _nativeJson(400, {
          'error': 'invalid_request',
          'error_description': 'invalid request',
        });
      }
    }

    _nativeTenantId = fields['tenant_id'];
    _nativeClientId = fields['client_id'];
    _nativeExpired = false;
    _liveNativeHandle = _mintNativeHandle();

    return _nativeJson(200, {
      'auth_session': _liveNativeHandle,
      if (startNext.isNotEmpty) 'next': startNext,
      if (startAvailableMethods != null)
        'available_methods': startAvailableMethods,
    });
  }

  Future<http.Response> _handleNativeVerify(Map<String, String> fields) async {
    final live = _liveNativeHandle;
    if (live == null) return _nativeInvalidSession();

    // Handle lifecycle, in the spec order. Every branch renders the SAME body.
    if (fields['auth_session'] != live) return _nativeInvalidSession();
    if (_nativeExpired) return _nativeInvalidSession();
    if (fields['tenant_id'] != _nativeTenantId) return _nativeInvalidSession();
    if (fields['client_id'] != _nativeClientId) return _nativeInvalidSession();

    if (_nativeScript.isEmpty) {
      fail('FakeAoidEndpoint: /oauth/native/verify was called with no scripted '
          'step left. Call scriptNativeCeremony([...]) — an unscripted verify '
          'must fail LOUDLY, never fall through to a default success.');
    }
    // Outcomes that never reach the ceremony service leave the handle ALIVE.
    //
    // the spec nativeWriteAllowed applies the region write gate BEFORE
    // r.nativeLogin.Verify is called — its mutation 12 ("the gate let 1
    // call(s) through") proves that ordering is load-bearing — so a replica's
    // 503 cannot have burned the handle. A dead socket is modelled the same
    // way: in this fixture the request never arrived.
    //
    // Found by the flow's test 6, which failed with AoidFlowRestartRequired
    // where a resubmission after a 503 should have completed.
    final peeked = _nativeScript.first;
    if (peeked is FakeNativeUnavailable) {
      _nativeScript.removeAt(0);
      return _nativeJson(
        503,
        {
          'error': 'temporarily_unavailable',
          'error_description': 'this region cannot accept writes',
        },
        extraHeaders: {'retry-after': '${peeked.retryAfterSeconds}'},
      );
    }
    if (peeked is FakeNativeNetworkFailure) {
      _nativeScript.removeAt(0);
      throw http.ClientException('fixture: simulated native socket failure');
    }

    final step = _nativeScript.removeAt(0);

    // Everything below REACHED the service, so the presented handle is
    // consumed either way (the spec: Consume burns it, then Rotate mints the
    // successor).
    _liveNativeHandle = null;

    switch (step) {
      case FakeNativeAdvance():
        final successor = _mintNativeHandle();
        _liveNativeHandle = successor;
        return _nativeJson(401, {
          'error': 'insufficient_authorization',
          'error_description': 'additional authorization required',
          'auth_session': successor,
          'next': step.next,
          if (step.availableMethods.isNotEmpty)
            'available_methods': step.availableMethods,
          if (step.webauthnChallenge != null)
            'webauthn_challenge': jsonDecode(step.webauthnChallenge!),
        });

      case FakeNativeReject():
        // the spec enumeration-parity reference response: the key set is
        // EXACTLY [auth_session, error, error_description]. No `next`, no
        // `available_methods` — that is the ONLY difference between a wrong
        // password and a correct one that needs MFA.
        final successor = _mintNativeHandle();
        _liveNativeHandle = successor;
        return _nativeJson(401, {
          'error': 'insufficient_authorization',
          'error_description': 'additional authorization required',
          'auth_session': successor,
        });

      case FakeNativeTerminal():
        // EXACTLY one key. A spare auth_session would leave a live handle
        // after the ceremony ended (the spec mutation 8).
        return _nativeJson(200, {
          'authorization_code': step.authorizationCode,
        });

      case FakeNativeRedirect():
        return _nativeJson(400, {
          'error': 'redirect_to_web',
          'error_description': 'this request must be completed in a web browser',
          'authorization_url': step.authorizationUrl,
        });

      case FakeNativeAttemptCapExceeded():
        // No successor: the ceremony is destroyed.
        return _nativeInvalidSession();

      case FakeNativeErrorStep():
        return _nativeJson(step.status, {
          'error': step.code,
          'error_description': step.description,
        });

      case FakeNativeUnavailable():
        return _nativeJson(
          503,
          {
            'error': 'temporarily_unavailable',
            'error_description': 'this region cannot accept writes',
          },
          extraHeaders: {'retry-after': '${step.retryAfterSeconds}'},
        );

      case FakeNativeServerError():
        return _nativeJson(500, {
          'error': 'server_error',
          'error_description': 'internal error',
        });

      case FakeNativeNetworkFailure():
        throw http.ClientException('fixture: simulated native socket failure');
    }
  }

  Future<http.Response> _handleToken(http.Request request) async {
    if (_nextTokenStatus != null) {
      final status = _nextTokenStatus!;
      _nextTokenStatus = null;
      return http.Response(
        jsonEncode(aoidErrorResponse(status)),
        status,
        headers: {'content-type': 'application/json'},
      );
    }

    final form = Uri.splitQueryString(request.body);
    final grantType = form['grant_type'];

    if (grantType == 'authorization_code') {
      _assertAuthorizationCodeBody(form);
    } else if (grantType == 'refresh_token') {
      _assertRefreshTokenBody(form);
    }

    final body = aoidTokenResponse(
      accessToken: tokenAccessToken,
      refreshToken: tokenRefreshToken,
      idToken: tokenIdToken,
    );
    if (omitIdToken) {
      body.remove('id_token');
    }

    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  Future<http.Response> _handleRevoke(http.Request request) async {
    if (_revokeShouldFailNetwork) {
      throw http.ClientException('fixture: simulated network failure');
    }
    return http.Response('', 200);
  }

  /// Frozen contract §1 assertion: the authorization_code grant POSTs
  /// `code`, `code_verifier`, `redirect_uri`, `client_id` and — public
  /// client, `token_endpoint_auth_method=none` — NEVER `client_secret`.
  void _assertAuthorizationCodeBody(Map<String, String> form) {
    expect(form['code'], isNotNull,
        reason: 'token POST (authorization_code) must send code');
    expect(form['code_verifier'], isNotNull,
        reason: 'token POST (authorization_code) must send code_verifier');
    expect(form['redirect_uri'], isNotNull,
        reason: 'token POST (authorization_code) must send redirect_uri');
    expect(form['client_id'], isNotNull,
        reason: 'token POST (authorization_code) must send client_id');
    expect(form.containsKey('client_secret'), isFalse,
        reason: 'public client (token_endpoint_auth_method=none) must NEVER '
            'send client_secret');
  }

  /// Frozen contract §1 assertion: the refresh_token grant POSTs
  /// `refresh_token`, `client_id` and — same public client — NEVER
  /// `client_secret`.
  void _assertRefreshTokenBody(Map<String, String> form) {
    expect(form['refresh_token'], isNotNull,
        reason: 'token POST (refresh_token) must send refresh_token');
    expect(form['client_id'], isNotNull,
        reason: 'token POST (refresh_token) must send client_id');
    expect(form.containsKey('client_secret'), isFalse,
        reason: 'public client (token_endpoint_auth_method=none) must NEVER '
            'send client_secret');
  }
}

/// Simulates the AOID `/oauth/authorize` browser round-trip without a real
/// browser: builds the redirect-back URL the platform browser-launch
/// callback (`FlutterWebAuth2.authenticate` or its test double) would
/// return, echoing [returnedState] and [code] onto [redirectUri].
///
/// Pass the SAME `state` the strategy generated to simulate a successful
/// round trip, or a DIFFERENT one to simulate a CSRF/state-mismatch attack.
String fakeAuthorize({
  required String redirectUri,
  required String returnedState,
  String code = 'FAKE_CODE',
}) =>
    '$redirectUri?code=$code&state=$returnedState';
