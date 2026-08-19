// AOID's `/oauth/token` REFRESH grant, including the ACTIVE-TENANT SWITCH.
//
// FORM IN, JSON OUT, ZERO CUSTOM REQUEST HEADERS — the same discipline as
// `aoid_native_client.dart`, and for the same reason.
//
// Riverpod-free and Flutter-free. It speaks `package:http`, matching
// `AoidNativeClient` and `AoidOidcAuthStrategy`; do NOT introduce `dio` here.

import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import '../claims/tenant_ref.dart' show AoidActiveTenantSlug;
import '../tenant/aoid_tenant_error.dart';
import 'aoid_endpoints.dart';
import 'aoid_error.dart';

/// A successful `/oauth/token` response.
///
/// [refreshToken] is nullable on purpose. A public-client refresh grant always
/// rotates and returns one, but a cookie-bound deployment (D4 Modes A and C)
/// legitimately gets none — the app's backend or the browser holds it. A
/// caller that REQUIRES the pair must check, rather than assume.
final class AoidTokenResponse {
  const AoidTokenResponse({
    required this.accessToken,
    this.refreshToken,
    this.idToken,
    this.tokenType = 'Bearer',
    this.expiresInSeconds,
    this.scope,
  });

  /// The NEW access token. This is what a tenant switch must be verified
  /// against — the id_token's `tnt` deliberately does not follow the switch
  /// (aoid the token claims`).
  final String accessToken;

  /// The ROTATED refresh token, when the deployment holds one client-side.
  final String? refreshToken;

  /// The OIDC id_token, when AOID emitted one.
  final String? idToken;

  final String tokenType;
  final int? expiresInSeconds;
  final String? scope;
}

/// Speaks AOID's `/oauth/token` refresh grant.
///
/// ## `active_tenant` is a FORM FIELD, not a header
///
/// aoid the token endpoint reads it from the POST body.
/// Keeping it in the body is what makes this a CORS **simple request** with no
/// preflight. Verified live 2026-08-01 against `auth.aocyber.ai`: `/oauth/token`
/// answers preflight `204` with `access-control-allow-origin: *` and sets no
/// `Access-Control-Allow-Credentials`.
///
/// **Do not "tidy" it into an `Active-Tenant` request header.** Any header
/// beyond a CORS-safelisted content type provokes a preflight and breaks every
/// browser caller at once. (The prohibited spelling is deliberately not written
/// out here: the spec gate greps this file for it, and a warning comment
/// containing the very string it forbids would trip a check meant to catch a
/// real header. The property itself is proven by test-list item 2, which
/// asserts the OUTGOING header map's key set — a far stronger check than a
/// grep.)
class AoidTokenClient {
  const AoidTokenClient({
    required AoidEndpoints endpoints,
    required http.Client httpClient,
    required String clientId,
  }) : _endpoints = endpoints,
       _http = httpClient,
       _clientId = clientId;

  final AoidEndpoints _endpoints;
  final http.Client _http;
  final String _clientId;

  /// THE header map. One entry, forever. See the class doc, and
  /// `AoidNativeClient._formHeaders` for the measured details.
  static const Map<String, String> _formHeaders = {
    'content-type': 'application/x-www-form-urlencoded',
  };

  /// Refreshes the token pair, optionally SWITCHING the active tenant.
  ///
  /// [activeTenant] accepts ONLY an [AoidActiveTenantSlug]. Passing
  /// the id_token's home-tenant UUID is a COMPILE error here rather than a
  /// confusing runtime `invalid_grant` — this is the one call site where that
  /// mistake would actually be made, and D5 exists to make it unwritable.
  Future<AoidTokenResponse> refresh({
    required String refreshToken,
    AoidActiveTenantSlug? activeTenant,
  }) async {
    final http.Response response;
    try {
      response = await _http.post(
        _endpoints.token,
        headers: _formHeaders,
        body: <String, String>{
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': _clientId,
          // FORM FIELD, never a header. See the class doc.
          if (activeTenant != null) 'active_tenant': activeTenant.slug,
        },
      );
    } on http.ClientException {
      throw const AoidTransportError(AoidTransportFailureKind.network);
    } on SocketException {
      throw const AoidTransportError(AoidTransportFailureKind.network);
    }
    return _interpret(response, carriedActiveTenant: activeTenant != null);
  }

  AoidTokenResponse _interpret(
    http.Response response, {
    required bool carriedActiveTenant,
  }) {
    // 503 is read before the body: a replica refuses the write before the
    // service is ever reached, so there is no decision in there to read.
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

    final accessToken = body['access_token'];
    if (response.statusCode == 200 &&
        accessToken is String &&
        accessToken.isNotEmpty) {
      final refresh = body['refresh_token'];
      final id = body['id_token'];
      final tokenType = body['token_type'];
      final expiresIn = body['expires_in'];
      final scope = body['scope'];
      return AoidTokenResponse(
        accessToken: accessToken,
        refreshToken: refresh is String && refresh.isNotEmpty ? refresh : null,
        idToken: id is String && id.isNotEmpty ? id : null,
        tokenType: tokenType is String && tokenType.isNotEmpty
            ? tokenType
            : 'Bearer',
        expiresInSeconds: expiresIn is int ? expiresIn : null,
        scope: scope is String && scope.isNotEmpty ? scope : null,
      );
    }

    final error = body['error'];

    // ── THE ONE BRANCH THIS the spec EXISTS FOR ──────────────────────────────────
    //
    // `invalid_grant` on a call that CARRIED `active_tenant` is a tenant
    // DENIAL, not an authentication failure. Routing it to `AoidError` — as
    // every other `invalid_grant` here is routed — signs the user out for
    // asking about a workspace they are not in, because that is exactly the
    // family `AuthNotifier.restoreSession` (auth_provider.dart:410-413) and
    // AODex's Dio 401 interceptor act on.
    //
    // DISAMBIGUATION IS BY REQUEST CONTEXT, NOT BY RESPONSE. AOID makes the
    // two byte-identical on purpose (the token service) so the endpoint is
    // not a membership oracle, so there is nothing in `response` to read. The
    // residual ambiguity — a refresh token that died DURING a switch — is
    // resolved toward NOT signing the user out, and self-corrects on the next
    // ordinary refresh. See AoidTenantDenied's doc comment.
    if (error == 'invalid_grant' && carriedActiveTenant) {
      throw const AoidTenantDenied();
    }

    if (error is String) {
      final code = _codeFor(error);
      if (code != null) throw AoidError(code);
    }

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
    // `invalid_grant` means the presented refresh token was not honoured.
    'invalid_grant' => AoidErrorCode.invalidSession,
    _ => null,
  };
}
