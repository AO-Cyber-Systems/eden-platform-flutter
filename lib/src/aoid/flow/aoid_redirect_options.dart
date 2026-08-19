// Per-consumer configuration for the AOID browser hop (the spec, D7).
//
// Every field here is a one-line setting with a total-failure blast radius,
// and every one of them is invisible until it happens to a user. The package
// defaults were read from the RESOLVED source in ~/.pub-cache
// (flutter_web_auth_2-5.0.3), not from upstream docs describing a version this
// repo does not use.
//
// RIVERPOD-FREE, like every file under lib/src/aoid/flow/. The package name
// itself is a banned literal in this directory (the firewall is a grep), so
// it is spelled in caps here and nowhere as an import.

import 'package:flutter_web_auth_2/flutter_web_auth_2.dart'
    show FlutterWebAuth2Options;

/// Per-consumer configuration for the AOID browser hop.
///
/// # `callbackScheme` is REQUIRED and has no default
///
/// A shared library cannot guess a per-app bundle identifier.
/// `social_auth_service.dart:37` shipped a hardcoded PERSONAL one — a real
/// developer's reverse-DNS bundle id — to every consumer of this package;
/// the spec removed it and this type must not reintroduce the shape. Unset
/// is a compile error (`required`); blank or malformed fails fast at
/// construction, not at the browser hop, where the failure would be a
/// mystery.
///
/// (The offending literal is deliberately not repeated here: it is a banned
/// string under `lib/`, gated by item 4 of
/// `test/aoid/flow/aoid_redirect_options_test.dart`, and a gate that its own
/// documentation trips is a gate someone weakens.)
///
/// Registration is per (app, platform), and the FULL redirect URI must be
/// EXACT-match registered on the AOID client
/// (`aoid/the token service`):
///
/// | Platform    | Where the scheme is registered                            |
/// | ----------- | --------------------------------------------------------- |
/// | iOS / macOS | `Info.plist` -> `CFBundleURLTypes` / `CFBundleURLSchemes`  |
/// | Android     | `flutter_web_auth_2` 5.x `CallbackActivity` intent-filter  |
/// | Web         | scheme is `https`; the target is the dedicated `auth.html` |
///
/// # Why this type is not `const`
///
/// The constructor VALIDATES. A `const` constructor cannot run a check, and a
/// scheme that is wrong is worth catching at construction rather than three
/// screens later inside an OS auth session. Validation beats const-ness here.
class AoidRedirectOptions {
  /// Throws [ArgumentError] naming `callbackScheme` when it is blank or is not
  /// a syntactically valid URL scheme.
  AoidRedirectOptions({
    required this.callbackScheme,
    this.preferEphemeral = false,
    this.watchdog = const Duration(seconds: 20),
  }) {
    _validateScheme(callbackScheme);
  }

  /// `flutter_web_auth_2`'s own scheme rule
  /// (`flutter_web_auth_2.dart:28` — `RegExp(r'^[a-z][a-z\d+.-]*$')`).
  /// Applied HERE, at configuration time, so a bad scheme is a startup error
  /// rather than an `ArgumentError` thrown from inside the auth session.
  static final RegExp _schemePattern = RegExp(r'^[a-z][a-z\d+.-]*$');

  static void _validateScheme(String scheme) {
    if (scheme.trim().isEmpty) {
      throw ArgumentError.value(
        scheme,
        'callbackScheme',
        'AoidRedirectOptions.callbackScheme is REQUIRED and has no default. '
            'Set the custom URL scheme this app registered for the AOID '
            'callback (iOS/macOS Info.plist CFBundleURLSchemes; Android the '
            "flutter_web_auth_2 CallbackActivity intent-filter; 'https' on "
            'web). A shared library cannot guess a per-app bundle identifier',
      );
    }
    if (!_schemePattern.hasMatch(scheme)) {
      throw ArgumentError.value(
        scheme,
        'callbackScheme',
        'not a valid URL scheme: must match ^[a-z][a-z\\d+.-]\$ — pass the '
            "SCHEME alone ('edenbiz'), not a full URI ('edenbiz://auth')",
      );
    }
  }

  /// The custom URL scheme this app registered for the AOID callback — the
  /// scheme ALONE (`edenbiz`), never a full URI (`edenbiz://auth`).
  ///
  /// `https` on web, where the callback is a universal-link-style target
  /// served by the dedicated `auth.html` page.
  final String callbackScheme;

  /// **iOS / macOS only.** `false` shares the Safari cookie jar.
  ///
  /// That is what delivers cross-app SSO — the three aofamily apps depend on
  /// it (`aofamily/browser/.../aoid_auth_service.dart:20-26`) — AND what
  /// triggers the *"«App» Wants to Use "aocyber.ai" to Sign In"* consent alert
  /// that users find alarming.
  ///
  /// Prefer `false` for consumer SSO, `true` for security-sensitive contexts.
  /// This is a PRODUCT decision, so it is EXPOSED rather than inherited
  /// silently from the package (which also defaults it to `false`,
  /// `flutter_web_auth_2-5.0.3/lib/src/options.dart:64`).
  ///
  /// **Not a cross-platform privacy guarantee.** Android Custom Tabs share the
  /// Chrome cookie jar regardless of this flag, and it has no effect at all on
  /// web. Do not document it as one.
  final bool preferEphemeral;

  /// How long to wait before ADVISING that the browser may have blocked the
  /// sign-in window. A HEURISTIC, not a detection, and never terminal.
  ///
  /// On web a blocked popup genuinely cannot be detected: `url_launcher_web`
  /// opens with `'noopener,noreferrer'` and its own doc says so —
  /// *"Always returns `true`... Because `noopener` is used as a window
  /// feature, it can not be detected if the window was opened successfully."*
  /// (`url_launcher_web-2.4.3/lib/url_launcher_web.dart:64-90`).
  /// `flutter_web_auth_2` then polls on a 1-second timer until its `timeout`,
  /// which defaults to `5 * 60` (`options.dart:66`) — so the untreated failure
  /// is a 300-second spinner ending in a generic timeout.
  ///
  /// This watchdog fronts that with an actionable message at ~20s. It
  /// deliberately does NOT shorten the underlying `timeout`: a slow-but-live
  /// ceremony (a user reading a consent screen, or completing MFA on a second
  /// device) must not be cancelled by a heuristic.
  final Duration watchdog;

  /// The options object handed to the authorize call.
  ///
  /// Kept as a method rather than inlined at the call site so that a test can
  /// assert on the exact instance the browser leg receives — a field that is
  /// set but never threaded through is the common failure, and a field-level
  /// assertion would miss it.
  FlutterWebAuth2Options toFlutterWebAuth2Options() => FlutterWebAuth2Options(
    preferEphemeral: preferEphemeral,

    // flutter_web_auth_2 defaults useWebview to TRUE
    // (flutter_web_auth_2-5.0.3/lib/src/options.dart:69). A WebView is
    // exactly what Google blocks for social login: the leg fails with
    // disallowed_useragent. Forced, and
    // deliberately NOT consumer-settable — there is no social IdP for which
    // an embedded WebView is the right answer.
    useWebview: false,
  );

  @override
  String toString() =>
      'AoidRedirectOptions(callbackScheme: $callbackScheme, '
      'preferEphemeral: $preferEphemeral, watchdog: $watchdog)';
}
