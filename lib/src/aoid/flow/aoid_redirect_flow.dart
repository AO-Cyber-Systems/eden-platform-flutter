// The AOID browser hop, code-only (the spec, SDK-04, D6 + D7).
//
// the issuer cannot embed everything: social IdPs block embedded login
// outright and PIV needs OS-level certificate selection, so both force a hop
// to a real browser. D7 makes that a FIRST-CLASS path rather than an error
// case — AoidFlowRedirectRequired is what produces it, and this is the
// other half: open the browser, take the CODE back.
//
// RIVERPOD-FREE, like every file under lib/src/aoid/flow/.
//
// # NOTHING HERE THROWS FOR AN EXPECTED OUTCOME, AND THAT IS A DECISION
//
// [AoidRedirectFlow.start] returns a sealed [AoidRedirectOutcome] for every
// outcome a user can cause — success, cancellation, a token-bearing callback,
// a state mismatch, a dead platform channel. It does not throw.
//
// That is not merely stylistic. riverpod 3 RETRIES A FAILED PROVIDER BY
// DEFAULT: `ProviderContainer.defaultRetry` is the FALLBACK, not an opt-in
// (element.dart:685 — `origin.retry ?? container.retry ?? defaultRetry`), and
// it is 10 attempts on a 200ms-doubling backoff, a 38.2-SECOND window. It
// declines to retry only `ProviderException` and `Error`; Dart's `Error` means
// PROGRAMMING faults, so every ordinary `Exception` IS retried. On each retry
// the element calls `invalidateSelf(asReload: false)`, so the provider returns
// to `AsyncLoading` — and because `AsyncValue.when` tests `isLoading` first,
// the `error:` arm is UNREACHABLE for the whole window.
//
// Applied to a browser hop that would mean: a user who cancels sees a spinner
// for 38 seconds, and the ceremony is silently re-attempted up to ten times —
// re-opening the browser each time. That is the worst possible answer for an
// auth surface.
//
// Returning a VALUE makes riverpod's retry structurally unreachable for this
// flow, on any consumer, without anyone having to remember `retry: (_, __) =>
// null` at each call site. A consumer that wraps this in a provider gets the
// error arm immediately because there is no error to retry.
// Full analysis: aoid/.planning/reports/50-riverpod3-automatic-retry.md.

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart'
    show FlutterWebAuth2, FlutterWebAuth2Options;

import '../pkce.dart';
import '../transport/aoid_endpoints.dart';
import 'aoid_redirect_options.dart';
import 'aoid_verifier_stash.dart';

/// Injectable browser-launch signature.
///
/// `FlutterWebAuth2.authenticate` is a STATIC and therefore unmockable; both
/// existing implementations in this fleet solve that by injecting the callable
/// (`aoid_oidc_auth_strategy.dart:30-33`, and AODex's `NativeAuthClient`).
///
/// `options` is REQUIRED here, unlike the older `AuthorizeFn` next door, which
/// omits it entirely. That is the point: a `FlutterWebAuth2Options` that is
/// built but never threaded through is the common failure mode for exactly the
/// settings this the spec exists to force, and `required` makes forgetting it a
/// compile error. `FlutterWebAuth2.authenticate` remains assignable because its
/// own `options` parameter is optional.
typedef AoidAuthorizeFn =
    Future<String> Function({
      required String url,
      required String callbackUrlScheme,
      required FlutterWebAuth2Options options,
    });

/// Injectable timer constructor, so the watchdog is testable without waiting
/// 20 real seconds. Defaults to `Timer.new`.
typedef AoidTimerFactory = Timer Function(Duration, void Function());

/// Why a callback was refused. TELEMETRY, not UI copy.
enum AoidRedirectRejection {
  /// The callback carried an access, refresh or id token. D6: refused, never
  /// used, no matter what a transitional server sends.
  tokenInCallback,

  /// The echoed `state` did not match the one this flow issued (CSRF).
  stateMismatch,

  /// No `code` parameter, or an empty one.
  missingCode,

  /// The authorization server reported an `error` other than a user denial.
  serverError,

  /// The callback was not a parseable URL.
  malformedCallback,

  /// A same-tab return arrived with no stashed verifier — the exchange cannot
  /// succeed, so it must not be attempted.
  verifierLost,
}

/// How the browser hop ended. Sealed, so a caller cannot forget a case.
sealed class AoidRedirectOutcome {
  const AoidRedirectOutcome();
}

/// Success: spend [code] at `/oauth/token` together with [codeVerifier].
///
/// There is deliberately no token field of any kind. There is nothing here for
/// a caller to opportunistically use if a stale server appends one.
final class AoidRedirectCode extends AoidRedirectOutcome {
  const AoidRedirectCode({
    required this.code,
    required this.codeVerifier,
    this.state,
  });

  /// The single-use, PKCE-bound authorization code.
  final String code;

  /// The RFC 7636 verifier this code is bound to. Required by the exchange.
  final String codeVerifier;

  /// The echoed `state`, already verified where verification was possible.
  final String? state;

  @override
  String toString() =>
      'AoidRedirectCode(code: <redacted>, '
      'codeVerifier: <redacted>, state: <redacted>)';
}

/// The user dismissed the browser, or denied at the IdP.
///
/// NOT an error, and not a failure — cancelling is a legitimate thing to do.
/// It is a distinct outcome precisely so a caller renders "signed out" rather
/// than an error banner, and so no retry machinery anywhere treats it as
/// something to attempt again.
final class AoidRedirectCancelled extends AoidRedirectOutcome {
  const AoidRedirectCancelled();

  @override
  String toString() => 'AoidRedirectCancelled()';
}

/// The callback arrived but was refused. See [reason].
final class AoidRedirectRejected extends AoidRedirectOutcome {
  const AoidRedirectRejected(this.reason);

  final AoidRedirectRejection reason;

  @override
  String toString() => 'AoidRedirectRejected(${reason.name})';
}

/// No authentication decision was reached — the platform channel failed, the
/// browser could not be opened, or the package timed out.
///
/// [detail] is TELEMETRY ONLY, never UI copy.
final class AoidRedirectUnavailable extends AoidRedirectOutcome {
  const AoidRedirectUnavailable(this.detail);

  final String detail;

  @override
  String toString() => 'AoidRedirectUnavailable($detail)';
}

/// Advisory that the sign-in window may have been blocked. A HEURISTIC.
///
/// A blocked popup genuinely CANNOT be detected: `url_launcher_web` opens with
/// `'noopener,noreferrer'` and its own doc says as much
/// (`url_launcher_web-2.4.3/lib/url_launcher_web.dart:64-90`). So this claims
/// nothing — it offers [authorizeUrl] as a same-tab fallback and leaves the
/// ceremony running, because a slow-but-live login (a consent screen being
/// read, MFA on a second device) must never be cancelled by a guess.
class AoidRedirectBlockedHint {
  const AoidRedirectBlockedHint({
    required this.elapsed,
    required this.authorizeUrl,
  });

  /// How long the ceremony had been open when the advice fired.
  final Duration elapsed;

  /// Navigate the CURRENT tab here to continue without a popup.
  final Uri authorizeUrl;

  /// Suggested copy. Deliberately hedged — it must not claim certainty.
  String get message =>
      'Your browser may have blocked the sign-in window. '
      'You can continue signing in on this page instead.';

  @override
  String toString() =>
      'AoidRedirectBlockedHint(elapsed: $elapsed, url: <redacted>)';
}

/// Drives the AOID browser hop and hands back an authorization CODE.
///
/// It never returns, holds or parses a token. The exchange is somebody else's
/// job — [AoidCodeSink] in Mode A, or a direct `POST /oauth/token` in Modes
/// B/C — which is what keeps a token out of every URL this class touches.
class AoidRedirectFlow {
  AoidRedirectFlow({
    required AoidEndpoints endpoints,
    required String clientId,
    required String redirectUri,
    required AoidRedirectOptions options,
    List<String> scopes = const <String>['openid', 'profile', 'email'],
    AoidAuthorizeFn? authorize,
    AoidVerifierStash? stash,
    bool isWeb = kIsWeb,
    PkcePair Function()? generatePkce,
    AoidTimerFactory? createTimer,
  }) : _endpoints = endpoints,
       _clientId = clientId,
       _redirectUri = redirectUri,
       _options = options,
       _scopes = scopes,
       _authorize = authorize ?? FlutterWebAuth2.authenticate,
       _stash = stash ?? aoidVerifierStashFor(isWeb: isWeb),
       _isWeb = isWeb,
       _generatePkce = generatePkce ?? PkceGenerator.generate,
       _createTimer = createTimer ?? Timer.new;

  final AoidEndpoints _endpoints;
  final String _clientId;
  final String _redirectUri;
  final AoidRedirectOptions _options;
  final List<String> _scopes;
  final AoidAuthorizeFn _authorize;
  final AoidVerifierStash _stash;
  final bool _isWeb;
  final PkcePair Function() _generatePkce;
  final AoidTimerFactory _createTimer;

  /// PKCE material for the in-flight hop. Held in memory for the popup and
  /// native paths, where the isolate survives; the same-tab path cannot rely
  /// on it, which is what [_stash] is for.
  PkcePair? _pending;

  /// Callback parameters that must never be honoured (D6).
  ///
  /// Read as NAMES against the parsed parameter map — the values are never
  /// pulled out, not into a variable and not into a log line, because a value
  /// that is read is a value that can leak.
  static const List<String> _forbiddenCallbackParams = <String>[
    'access_token',
    'refresh_token',
    'id_token',
  ];

  /// The AOID `/oauth/authorize` URL for [pair].
  Uri buildAuthorizeUrl(PkcePair pair) => _endpoints.authorize.replace(
    queryParameters: <String, String>{
      'response_type': 'code',
      'client_id': _clientId,
      'redirect_uri': _redirectUri,
      'scope': _scopes.join(' '),
      'code_challenge': pair.codeChallenge,
      'code_challenge_method': 'S256',
      'state': pair.state,
      'nonce': pair.nonce,
    },
  );

  /// Open the browser and wait for the callback.
  ///
  /// # This method is NOT `async`, on purpose
  ///
  /// An `await` before the launch ends the user-gesture task, after which the
  /// browser stops treating the subsequent `window.open` as user-initiated —
  /// which is precisely what gets the popup blocked, turning the watchdog from
  /// a safety net into the normal path. Written with `.then` rather than
  /// `async`/`await`, launching synchronously from the caller's gesture is a
  /// STRUCTURAL property of this method rather than a comment someone has to
  /// keep honouring.
  ///
  /// [onPossiblyBlocked] fires once, after [AoidRedirectOptions.watchdog], if
  /// the ceremony is still open. It is advice, not a result: the returned
  /// future stays pending and a late success still wins.
  Future<AoidRedirectOutcome> start({
    void Function(AoidRedirectBlockedHint hint)? onPossiblyBlocked,
  }) {
    final pair = _generatePkce();
    final authorizeUrl = buildAuthorizeUrl(pair);
    _pending = pair;

    // Stashed BEFORE the launch. After the launch is too late on web: on a
    // same-tab navigation the page may unload before any continuation runs.
    if (_isWeb) _stash.save(pair.codeVerifier);

    // Started BEFORE the launch too. A watchdog armed afterwards measures from
    // the wrong instant, and on a synchronously-throwing launch never arms.
    Timer? watchdog;
    if (onPossiblyBlocked != null) {
      watchdog = _createTimer(_options.watchdog, () {
        onPossiblyBlocked(
          AoidRedirectBlockedHint(
            elapsed: _options.watchdog,
            authorizeUrl: authorizeUrl,
          ),
        );
      });
    }

    final Future<String> callback;
    try {
      // No `await` above this line. See the doc comment.
      callback = _authorize(
        url: authorizeUrl.toString(),
        callbackUrlScheme: _options.callbackScheme,
        options: _options.toFlutterWebAuth2Options(),
      );
    } catch (e) {
      watchdog?.cancel();
      _finish();
      return Future<AoidRedirectOutcome>.value(
        AoidRedirectUnavailable('browser launch failed: ${e.runtimeType}'),
      );
    }

    return callback.then<AoidRedirectOutcome>(
      (String url) {
        watchdog?.cancel();
        return _interpret(url, pair, expectedState: pair.state);
      },
      onError: (Object e, StackTrace _) {
        watchdog?.cancel();
        _finish();
        return _interpretLaunchError(e);
      },
    );
  }

  /// Stash the verifier and hand back the URL to navigate the CURRENT tab to.
  ///
  /// This is the fallback [AoidRedirectBlockedHint] offers. The stash is NOT
  /// cleared here — surviving the page unload is the entire point — and the
  /// returning page calls [resume].
  Uri beginSameTabFallback([PkcePair? pair]) {
    final material = pair ?? _pending ?? _generatePkce();
    _pending = material;
    _stash.save(material.codeVerifier);
    return buildAuthorizeUrl(material);
  }

  /// Interpret a callback that arrived after a FULL-PAGE reload.
  ///
  /// The instance that started the ceremony is gone, so the verifier comes
  /// from the stash rather than from memory. Synchronous, and it never throws.
  ///
  /// [expectedState] is optional because after a reload there usually is none:
  /// only the verifier is stashed, so PKCE's binding carries the CSRF property
  /// on this path (see aoid_verifier_stash.dart). Pass it when the calling
  /// page does have it.
  AoidRedirectOutcome resume(String callbackUrl, {String? expectedState}) {
    final verifier = _stash.restore();
    if (verifier == null || verifier.isEmpty) {
      _finish();
      return const AoidRedirectRejected(AoidRedirectRejection.verifierLost);
    }
    return _interpret(
      callbackUrl,
      PkcePair(
        codeVerifier: verifier,
        codeChallenge: '',
        state: expectedState ?? '',
        nonce: '',
      ),
      expectedState: expectedState,
    );
  }

  /// True when a same-tab return has a verifier waiting for it.
  bool get hasStashedVerifier {
    final v = _stash.restore();
    return v != null && v.isNotEmpty;
  }

  AoidRedirectOutcome _interpret(
    String callbackUrl,
    PkcePair pair, {
    String? expectedState,
  }) {
    final Uri uri;
    try {
      uri = Uri.parse(callbackUrl);
    } on FormatException {
      _finish();
      return const AoidRedirectRejected(
        AoidRedirectRejection.malformedCallback,
      );
    }

    final params = <String, String>{...uri.queryParameters};
    // The implicit flow puts its response in the FRAGMENT. Refusing only the
    // query string would leave the older leak wide open.
    if (uri.fragment.isNotEmpty) {
      try {
        params.addAll(Uri.splitQueryString(uri.fragment));
      } on FormatException {
        // A fragment that is not a query string carries no parameters and is
        // simply ignored — it cannot smuggle one in.
      }
    }

    // D6 FIRST, before anything else is looked at. Checked by NAME; no value
    // is ever read out of the map.
    for (final forbidden in _forbiddenCallbackParams) {
      if (params.containsKey(forbidden)) {
        _finish();
        return const AoidRedirectRejected(
          AoidRedirectRejection.tokenInCallback,
        );
      }
    }

    if (params.containsKey('error')) {
      final code = params['error'];
      _finish();
      // A user declining at the IdP is a cancellation, not a failure.
      return (code == 'access_denied' || code == 'user_cancelled')
          ? const AoidRedirectCancelled()
          : const AoidRedirectRejected(AoidRedirectRejection.serverError);
    }

    final returnedState = params['state'];
    if (expectedState != null && returnedState != expectedState) {
      // Refused BEFORE the code is even looked at, so there is nothing for a
      // caller to exchange. The stash is dropped too — a rejected ceremony
      // must not leave PKCE material behind for the next one to trip over.
      _finish();
      return const AoidRedirectRejected(AoidRedirectRejection.stateMismatch);
    }

    final code = params['code'];
    if (code == null || code.isEmpty) {
      _finish();
      return const AoidRedirectRejected(AoidRedirectRejection.missingCode);
    }

    _finish();
    return AoidRedirectCode(
      code: code,
      codeVerifier: pair.codeVerifier,
      state: returnedState,
    );
  }

  AoidRedirectOutcome _interpretLaunchError(Object e) {
    // flutter_web_auth_2 signals a dismissed session as
    // PlatformException(code: 'CANCELED') — webview.dart:71, server.dart:64.
    // AODex's NativeAuthClient maps the same thing to a non-error; so do we.
    if (e is PlatformException && e.code.toUpperCase() == 'CANCELED') {
      return const AoidRedirectCancelled();
    }
    if (e is PlatformException) {
      return AoidRedirectUnavailable('platform: ${e.code}');
    }
    return AoidRedirectUnavailable('unexpected: ${e.runtimeType}');
  }

  /// Drop every trace of the ceremony. Called on EVERY terminal outcome, not
  /// only on success — a cancelled or rejected hop must leave nothing behind.
  void _finish() {
    _pending = null;
    _stash.clear();
  }
}
