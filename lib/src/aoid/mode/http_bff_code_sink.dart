// The ONE shipped AoidCodeSink — Mode A over HTTP.
//
// RIVERPOD-FREE BY CONSTRUCTION (see storage/aoid_token_store.dart's header).
//
// Uses `package:http` with an injected client, matching AoidNativeClient
// and the existing fixture suite. Do NOT introduce `dio` into the aoid
// module even though it is in the pubspec: mixing transports forks the fakes
// that the spec and the spec all extend.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../aoid_session.dart';
import 'aoid_code_sink.dart';

/// Posts `{code, code_verifier}` to the consuming app's own backend.
///
/// ## THE WIRE CONTRACT (the spec implements the other side of this)
///
/// ```
/// POST <exchangeUrl>
/// content-type: application/x-www-form-urlencoded
///
/// code=<authorization code>&code_verifier=<pkce verifier>[&redirect_uri=<uri>]
/// ```
///
/// Response:
/// - **2xx** — success. `Set-Cookie` carries the session; it MUST be
///   `HttpOnly` and MUST carry a `SameSite` attribute.
/// - **non-2xx** — failure. The backend MUST NOT signal failure with a 2xx,
///   because this client treats any 2xx as a completed sign-in.
///
/// **The response BODY is not read.** That is deliberate and is the narrowest
/// contract that makes Mode A work: 2xx plus a cookie. A richer JSON body would
/// be a shape the spec has to match blindly, and any token in it would be a token
/// this client is not supposed to hold.
///
/// ## Form encoding, not JSON
///
/// `application/x-www-form-urlencoded` is a CORS-safelisted content type;
/// `application/json` is not and provokes an `OPTIONS` preflight when the
/// frontend and backend are on different origins. Same reasoning as the spec
/// native client, and the same house style as the spec `active_tenant` form
/// field.
///
/// ## Cookies and credentials on web
///
/// If the app's frontend and backend are on DIFFERENT origins, the browser will
/// not store the response cookie unless the request is made with credentials.
/// This class does not construct its transport, so that is the consumer's
/// choice: pass a `BrowserClient()..withCredentials = true`. Same-origin —
/// the common case, and AODex's — needs nothing.
///
/// On native, `ConnectCookieInterceptor` is a no-op on web
/// (connect_cookie_interceptor.dart:44-49) because the browser owns the jar;
/// on native the shared `cookieJar` applies. This class adds no cookie
/// plumbing of its own for either.
class HttpBffCodeSink implements AoidCodeSink {
  /// The path AODex's Go backend implements.
  ///
  /// Exposed so a consumer can BUILD its [exchangeUrl] from an origin without
  /// guessing. It is deliberately **not applied automatically** — see
  /// [exchangeUrl].
  static const String conventionalExchangePath = '/auth/aoid/native/exchange';

  /// Creates a sink posting to [exchangeUrl].
  ///
  /// [exchangeUrl] is REQUIRED and must be absolute. There is no default and no
  /// fallback: `auth_provider.dart:56` falls back to a hardcoded localhost URL
  /// on a forbidden port, and that pattern must not be copied here. A silent
  /// default would post a live authorization code to somewhere nobody chose.
  ///
  /// [requireSecureSessionCookie] rejects a 2xx whose `Set-Cookie` is visible
  /// and carries no `HttpOnly` + `SameSite` cookie. Defaults to on. It cannot
  /// fire on web — an httpOnly cookie is invisible to JS by definition — so
  /// this is a development-time and native-time check, not an enforcement the
  /// SDK can promise. Turn it off only for a backend that genuinely cannot
  /// comply.
  HttpBffCodeSink({
    required this.exchangeUrl,
    required http.Client httpClient,
    bool isWeb = kIsWeb,
    this.requireSecureSessionCookie = true,
  }) : _http = httpClient,
       _isWeb = isWeb {
    if (!exchangeUrl.hasScheme || exchangeUrl.host.isEmpty) {
      throw ArgumentError.value(
        exchangeUrl.toString(),
        'exchangeUrl',
        'the Mode A exchange URL must be absolute — it names YOUR OWN '
            "application's backend, which holds the client secret. It is not "
            'defaulted, because a default would post a live authorization code '
            'to a host nobody chose.',
      );
    }
  }

  /// The app-backend endpoint that performs the confidential exchange.
  ///
  /// Whatever the consumer passed, unchanged. [conventionalExchangePath] is
  /// never appended: appending it would be a fallback by another name.
  final Uri exchangeUrl;

  /// See the constructor.
  final bool requireSecureSessionCookie;

  final http.Client _http;
  final bool _isWeb;

  /// THE header map. One entry — same contract as the spec native client.
  static const Map<String, String> _formHeaders = {
    'content-type': 'application/x-www-form-urlencoded',
  };

  @override
  Future<AoidSession> submit({
    required String code,
    required String codeVerifier,
    String? redirectUri,
  }) async {
    final http.Response response;
    try {
      // EXACTLY ONE request. No retry, ever: the code is single-use and a
      // retry may re-present one the backend already spent successfully.
      response = await _http.post(
        exchangeUrl,
        headers: _formHeaders,
        body: <String, String>{
          'code': code,
          // Correct and necessary. See AoidCodeSink's doc comment — this is
          // NOT the client secret.
          'code_verifier': codeVerifier,
          // Null-aware element: the key is omitted entirely when the caller
          // supplied no redirect_uri, rather than sent empty.
          'redirect_uri': ?redirectUri,
        },
      );
    } on http.ClientException {
      throw const AoidBffExchangeError(AoidBffFailureKind.unreachable);
    }

    final status = response.statusCode;
    if (status < 200 || status >= 300) {
      throw AoidBffExchangeError(
        status >= 500
            ? AoidBffFailureKind.backendError
            : AoidBffFailureKind.backendRefused,
        statusCode: status,
      );
    }

    _auditSessionCookie(response);

    // Mode A: the refresh token is on the backend and the session is the
    // cookie. There is no token to carry and no store to write to.
    return AoidSession.backendHeldCookie(isWeb: _isWeb);
  }

  /// Rejects a success whose session cookie is not `HttpOnly` + `SameSite`.
  ///
  /// Requires only that AT LEAST ONE cookie in the response carries both. A
  /// backend legitimately sets a JS-readable CSRF cookie alongside the session
  /// cookie (the double-submit pattern needs it readable), so demanding it of
  /// every cookie would refuse a correct backend.
  ///
  /// The consequence, stated rather than hidden: this cannot tell WHICH cookie
  /// is the session. It catches "the backend set no protected cookie at all",
  /// which is the mistake worth catching, and not "the backend protected the
  /// wrong one".
  void _auditSessionCookie(http.Response response) {
    if (!requireSecureSessionCookie) return;

    final raw = response.headers['set-cookie'];
    // Absent on web ALWAYS: an httpOnly cookie is invisible to script, so
    // there is nothing to inspect and nothing to conclude. Treating absence as
    // a failure would break every real web login.
    if (raw == null || raw.isEmpty) return;

    // `http` folds repeated Set-Cookie headers into one comma-joined value.
    // Splitting on the attribute boundary is imperfect, which is why the rule
    // is "at least one conformant cookie" rather than a per-cookie verdict.
    final hasProtected = raw
        .split(RegExp(r',(?=[^;=]+=)'))
        .any(
          (c) =>
              c.toLowerCase().contains('httponly') &&
              c.toLowerCase().contains('samesite'),
        );

    if (!hasProtected) {
      throw const AoidBffExchangeError(
        AoidBffFailureKind.insecureSessionCookie,
      );
    }
  }
}
