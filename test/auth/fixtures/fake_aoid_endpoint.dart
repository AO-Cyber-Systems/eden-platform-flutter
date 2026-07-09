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

  /// The fake endpoint's [http.Client]. Routes `POST {issuer}/oauth/token`
  /// and `POST {issuer}/oauth/revoke`; anything else is 404.
  http.Client get client => MockClient((request) async {
        capturedRequests.add(request);

        if (request.method == 'POST' && request.url.path.endsWith('/oauth/token')) {
          return _handleToken(request);
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/oauth/revoke')) {
          return _handleRevoke(request);
        }
        return http.Response('{"error":"not_found"}', 404);
      });

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

    return http.Response(
      jsonEncode(aoidTokenResponse(
        accessToken: tokenAccessToken,
        refreshToken: tokenRefreshToken,
      )),
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
