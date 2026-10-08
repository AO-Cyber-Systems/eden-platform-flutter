// ANTI-ROT GATE for lib/src/aoid/README.md.
//
// The README documents an SDK that eighteen packages depend on, and two of its
// claims exist because both have ALREADY caused real confusion in this
// codebase:
//
//   1. `EdenFeatureGate` is UI hinting ONLY. It is not a permission check.
//   2. AOID's `ent` claim and eden-biz's /api/v1/entitlements/bootstrap are
//      two UNRELATED axes that share a word.
//
// A document is the least durable artefact in a repository: nothing breaks
// when it goes stale. This file makes the load-bearing claims breakable, so a
// reword that drops one fails CI instead of silently misleading the next
// reader.
//
// # How to read a failure here
//
// Every reason string below names WHAT BREAKS IN THE WORLD if the claim
// disappears — not "the grep did not match". If you are here because you
// rewrote a section, restore the SUBSTANCE; do not weaken the predicate to fit
// new prose. That inverts the gate: it would then certify whatever the README
// happens to say.
//
// # Why predicates and not greps
//
// The issuer has now found the same defect in nine TRDs: `grep -c "PHRASE"`
// cannot tell which declaration it matched, survives the phrase drifting into
// a comment, and passes vacuously when the file is missing. So the claims are
// named predicates over the file's text, shared between the real README (items
// 2-8) and a deliberately-mutilated fixture (item 9). If a predicate cannot
// reject a README with the claim removed, it is not a gate, and item 9 is what
// proves each one can.

import 'dart:io';

// The ONE entrypoint the README tells consumers to use. Importing it here is
// itself an assertion: if the fold that the barrel consolidation performed is ever half-reverted,
// this file stops compiling and takes the whole gate with it.
import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_test/flutter_test.dart';

/// The path is relative to the package root, which is `flutter test`'s cwd.
const String kReadmePath = 'lib/src/aoid/README.md';

/// A load-bearing claim: a name, a predicate, and what breaks without it.
typedef ReadmeClaim = ({String name, bool Function(String) holds, String breaks});

/// Collapses whitespace so a claim cannot be broken by a line wrap.
///
/// This is not cosmetic. The claims layer lost a doc gate to exactly this: the prose
/// had wrapped as `tenant\n/// axis` and `contains('tenant axis')` went red on
/// a correct document. A gate that fails on reflow gets weakened, and a
/// weakened gate stops catching the real deletion.
String normalize(String src) => src.replaceAll(RegExp(r'\s+'), ' ');

/// Case-insensitive containment over the normalized text.
bool _has(String src, String needle) =>
    normalize(src).toLowerCase().contains(needle.toLowerCase());

/// Case-SENSITIVE containment — for Dart identifiers and URI literals, where
/// case is part of the value and a case-insensitive match would accept a
/// misspelling a consumer cannot compile or register.
bool _hasExact(String src, String needle) => normalize(src).contains(needle);

/// The claims, in the order the test list names them (items 2-8).
///
/// Each predicate demands the claim's SUBSTANCE, not one phrasing: where a
/// single sentence could be reworded harmlessly, the predicate accepts any of
/// several spellings but still requires the concept to be present.
final List<ReadmeClaim> kClaims = <ReadmeClaim>[
  (
    name: 'item 2 — EdenFeatureGate is UI hinting ONLY, and the server '
        're-verifies',
    holds: (src) =>
        _hasExact(src, 'EdenFeatureGate') &&
        _has(src, 'UI hinting') &&
        // The second half is the one that matters operationally: "hint only"
        // is advice, "the server re-verifies" is why the advice is safe.
        (_has(src, 'server always re-verifies') ||
            _has(src, 'server re-verifies') ||
            _has(src, 'always re-verified on the server')) &&
        _hasExact(src, 'entitlements/feature_gate.dart'),
    breaks: 'Without this, someone uses EdenFeatureGate as a PERMISSION CHECK. '
        'It is a client-side widget reading client-side state: an attacker '
        'flips it in devtools. Every entitlement it hides must be re-checked '
        'on the server, and this section is the only place that says so. '
        'the design notes names this as a required doc item BECAUSE IT HAS '
        'ALREADY CAUSED REAL CONFUSION.',
  ),
  (
    name: 'item 3 — AOID `ent` and eden-biz plan/billing entitlements are two '
        'unrelated axes',
    holds: (src) =>
        // Both systems must be NAMED. Naming only one leaves the reader
        // believing the word has a single meaning, which is the confusion.
        _hasExact(src, 'entitlements/bootstrap') &&
        _hasExact(src, 'identity_memberships') &&
        _has(src, 'ent') &&
        (_has(src, 'unrelated') || _has(src, 'not related')) &&
        (_has(src, 'do not conflate') ||
            _has(src, 'must not be conflated') ||
            _has(src, 'conflating')),
    breaks: 'Without this, a reader assumes AOID\'s `ent` claim gates BILLING '
        'features, or that a paid plan grants an identity role. They are '
        'different systems with different owners: `ent` comes from '
        'identity_memberships and means identity/role; eden-biz '
        '/api/v1/entitlements/bootstrap means plan/billing. They share only a '
        'word. the design notes names this as a required doc item BECAUSE IT HAS '
        'ALREADY CAUSED REAL CONFUSION.',
  ),
  (
    name: 'item 4 — all three deployment modes are documented and the web '
        'localStorage refresh token is marked FORBIDDEN',
    holds: (src) =>
        _hasExact(src, 'bff') &&
        _hasExact(src, 'publicPkce') &&
        _hasExact(src, 'sameOrigin') &&
        _has(src, 'forbidden') &&
        _hasExact(src, 'localStorage') &&
        // The forbidden thing is specifically a REFRESH token on WEB. A
        // README that says "localStorage is forbidden" without naming the
        // token would also forbid the ~1s authorization-code transit, which
        // is accepted by construction.
        _has(src, 'refresh token'),
    breaks: 'Without this, a consumer picks a mode by guessing, and the '
        'fourth option — a refresh token in web localStorage — looks like a '
        'convenient way to survive a page reload. It is durably readable by '
        'any XSS. D4 forbids it and the token store removed the CAPABILITY at four '
        'separate write paths; this section is the only thing telling a '
        'consumer not to rebuild it in their own app.',
  ),
  (
    name: 'item 5 — the forbidden posture SHIPPED until the issuer (the '
        'history, not just the rule)',
    holds: (src) => _has(src, 'shipped until'),
    breaks: 'THIS IS THE SINGLE MOST USEFUL SENTENCE IN THE DOCUMENT for a '
        'future reader deciding whether the storage restriction is real. A '
        'rule with no history reads as caution and gets traded away the first '
        'time someone hits a storage failure on web. A rule that says "this '
        'is what we actually shipped, to real users, until the issuer" does '
        'not. The token store measured it: four write paths, one of which nobody knew '
        'about. Deleting this sentence invites the pattern back.',
  ),
  (
    name: 'item 6 — both `tnt` semantics, and both Dart types by name',
    holds: (src) =>
        _hasExact(src, 'AoidActiveTenantSlug') &&
        _hasExact(src, 'AoidHomeTenantId') &&
        _has(src, 'slug') &&
        _has(src, 'uuid') &&
        _has(src, 'access token') &&
        _has(src, 'id_token'),
    breaks: 'Without this, `tnt` reads as one claim. It is two: the ACCESS '
        'token\'s `tnt` is the ACTIVE tenant SLUG and follows switching; the '
        'ID token\'s `tnt` is the HOME tenant UUID and does not. AOID\'s own '
        'tokens.go contradicted itself about this for months. Naming both '
        'Dart types is what lets a reader find the compile-time guard instead '
        'of re-deriving the trap from a token dump.',
  ),
  (
    name: 'item 7 — AOID owns authN, the consuming app owns authZ',
    holds: (src) =>
        _has(src, 'owns authN') &&
        _has(src, 'owns authZ') &&
        (_has(src, 'do not move authZ into AOID') ||
            _has(src, 'authZ does not move into AOID')),
    breaks: 'Without this boundary, every consuming app asks AOID to answer '
        '"may this user do X", and AOID accretes eighteen apps\' permission '
        'models. AOID resolves identity, membership and entitlements; the app '
        'maps ent[] onto its own roles. The chain is documented so nobody has '
        'to guess which end owns the decision.',
  ),
  (
    name: 'item 8 — the redirect-URI registration table, byte-exact',
    holds: (src) =>
        _hasExact(src, 'aodex://auth-callback') &&
        _hasExact(src, 'edenbiz://auth') &&
        _hasExact(src, 'auth.html') &&
        _has(src, 'exact'),
    breaks: 'AOID EXACT-MATCHES redirect URIs (the token service). '
        'A consumer that invents a trailing slash, or types `aodex://auth` '
        'instead of `aodex://auth-callback`, gets a rejected authorize request '
        'and no useful error. This table is the only place a consumer can '
        'read the registered values without reverse-engineering '
        'config/oauth-clients.yaml.',
  ),

  // ── items 10-14: the "Passkey sign-in (iOS and macOS)" section ──────────
  //
  // Numbered after item 9 (the positive-control group) so the existing items
  // keep their numbers. Item 9's machinery runs over the whole list, so each
  // of these is also checked against the real README (non-vacuity), against
  // an empty document, and against the README with its anchors deleted.
  (
    name:
        'item 10 — passkey prerequisites: Associated Domains on iOS AND '
        'macOS, an AASA on the AOID host, a macOS provisioning profile, the '
        'runtime OS floor, and pod install after the bump',
    holds: (src) =>
        _hasExact(src, 'com.apple.developer.associated-domains') &&
        _hasExact(src, 'webcredentials:') &&
        // BOTH platforms' entitlement files, by path: an iOS-only instruction
        // leaves the macOS app silently unassociated.
        _hasExact(src, 'ios/Runner/Runner.entitlements') &&
        _hasExact(src, 'macos/Runner/Release.entitlements') &&
        _hasExact(src, '.well-known/apple-app-site-association') &&
        _hasExact(src, '<TeamID>.<bundle id>') &&
        _has(src, 'provisioning profile') &&
        _has(src, 'iOS 16') &&
        _has(src, 'macOS 13') &&
        _has(src, 'pod install'),
    breaks:
        'Without these, a consumer bumps the ref, sees the button, taps '
        'it, and gets "not available on this device right now" with no idea '
        'why. Every one of these is configured OUTSIDE Dart (an entitlement, '
        'a file on the AOID host, a signing profile, a CocoaPods/SwiftPM '
        'resolve), so nothing in the SDK can detect or report which one is '
        'missing. This list is the only place a consumer learns them without '
        'reading Swift.',
  ),
  (
    name:
        'item 11 — what a missing prerequisite looks like: the unavailable '
        'sentence, the form stays on the password, no button where it cannot '
        'work',
    holds: (src) =>
        _hasExact(
          src,
          'Passkey sign-in is not available on this device right now. '
          'Use your password instead.',
        ) &&
        _has(src, 'stays on the password') &&
        _has(src, 'no button') &&
        _has(src, 'never shown'),
    breaks:
        'Without this, a consumer who sees the unavailable sentence '
        'debugs their Dart instead of their entitlement, and one who sees NO '
        'button on an old OS or an unlinked app files it as a bug. The two '
        'symptoms are deliberately different (a configuration the OS can only '
        'refuse at tap time vs a capability the SDK can probe up front), and '
        'the table is what maps each symptom back to its cause.',
  ),
  (
    name:
        'item 12 — cancel and "no passkey" are indistinguishable by design, '
        'and cancel is silent',
    holds: (src) =>
        _has(src, 'no passkey') &&
        _has(src, 'same cancellation') &&
        _has(src, 'treats both as a cancel'),
    breaks:
        'Without this, someone "improves" the form with a "you have no '
        'passkey" message. Apple\'s modal API cannot tell that case from a '
        'dismissed sheet, so the message would be wrong half the time, and '
        'when right it tells an onlooker whether the account holds a passkey.',
  ),
  (
    name:
        'item 13 — what is NOT provided: web (hosted page), Android, '
        'hardware security keys, second-factor security keys; the button is '
        'omitted there',
    holds: (src) =>
        _has(src, 'not provided') &&
        _has(src, 'hosted sign-in page') &&
        _has(src, 'Credential Manager') &&
        _has(src, 'hardware security keys') &&
        _has(src, 'second-factor step') &&
        _has(src, 'omitted'),
    breaks:
        'Without this, a web or Android consumer waits for a button that '
        'will never appear, or a team plans a security-key rollout on a '
        'ceremony the SDK does not run. Saying what is absent is what lets a '
        'consumer route those users to the hosted page instead.',
  ),
  (
    name:
        'item 14 — the channel name and the plugin class, for anyone '
        'debugging a MissingPluginException',
    holds: (src) =>
        _hasExact(src, 'eden_platform_flutter/aoid_passkey') &&
        _hasExact(src, 'MissingPluginException') &&
        _hasExact(src, 'AoidPasskeyPlugin'),
    breaks:
        'Without this, the only symptom of an unlinked native half (a '
        'missing button) has no searchable name attached. The channel string '
        'and the registrant entry are what a consumer greps for in their '
        'build to see whether the plugin is linked at all.',
  ),
];

// ── The passkey section's SOURCE bindings, as predicates ──────────────────
//
// Items 10-14 prove the README SAYS the right things. These prove the code
// still DOES them, and they take their inputs as strings so item 16 can feed
// each one a mutilated source and watch it fail. A binding that reads files
// itself cannot be given a broken input, and so can never be shown to bind.

/// The method channel both halves must declare, byte for byte.
const String kPasskeyChannel = 'eden_platform_flutter/aoid_passkey';

/// Drops `//` line comments (and so `///` doc comments) from Dart or Swift.
///
/// The bindings below look for DECLARATIONS. The Dart half quotes the channel
/// in its header comment too, so without this a renamed declaration would
/// still "match" through the comment. Naive about `//` inside a string, which
/// can only hide a match, never invent one.
String _stripLineComments(String src) => src
    .split('\n')
    .map((line) {
      final at = line.indexOf('//');
      return at < 0 ? line : line.substring(0, at);
    })
    .join('\n');

/// Joins Dart's adjacent string literals split across lines (`'a '\n  'b'`),
/// so a sentence the form wraps over two literals is matched as one.
String _joinAdjacentLiterals(String dart) =>
    dart.replaceAll(RegExp(r"'\s*\n\s*'"), '');

/// The README names the channel, and BOTH halves still declare that exact
/// name in code (not in a comment).
bool passkeyChannelBound({
  required String readme,
  required String dartHalf,
  required List<String> darwinSources,
}) =>
    _hasExact(readme, kPasskeyChannel) &&
    RegExp("=\\s*MethodChannel\\(\\s*'${RegExp.escape(kPasskeyChannel)}'")
        .hasMatch(_stripLineComments(dartHalf)) &&
    darwinSources
        .map(_stripLineComments)
        .any(
          (s) => RegExp(
            'FlutterMethodChannel\\(\\s*name:\\s*"'
            '${RegExp.escape(kPasskeyChannel)}"',
          ).hasMatch(s),
        );

/// The platforms `flutter.plugin.platforms` declares in a pubspec's text.
///
/// Reads indentation rather than parsing YAML (the package has no YAML
/// dependency to import, and must not gain one for a test). Empty when there
/// is no plugin block at all.
Set<String> declaredPluginPlatforms(String pubspec) {
  final plugin = RegExp(r'^  plugin:\s*$', multiLine: true).firstMatch(pubspec);
  if (plugin == null) return const <String>{};
  final rest = pubspec.substring(plugin.end);
  final platforms = RegExp(
    r'^    platforms:\s*$',
    multiLine: true,
  ).firstMatch(rest);
  if (platforms == null) return const <String>{};
  final names = <String>{};
  for (final line in rest.substring(platforms.end).split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final indent = line.length - trimmed.length;
    if (indent <= 4) break; // left the platforms block
    final key = RegExp(r'^([a-z]+):').firstMatch(trimmed);
    if (indent == 6 && key != null) names.add(key.group(1)!);
  }
  return names;
}

/// "Web, Android, Windows and Linux builds are unchanged" and "Not provided:
/// Android": the plugin is declared for iOS and macOS and NOTHING else, and
/// the class it registers is the one the README tells consumers to look for.
bool passkeyPlatformsBound({required String readme, required String pubspec}) =>
    _hasExact(readme, 'AoidPasskeyPlugin') &&
    _has(readme, 'declared for iOS and macOS only') &&
    declaredPluginPlatforms(pubspec).length == 2 &&
    declaredPluginPlatforms(pubspec).containsAll(const {'ios', 'macos'}) &&
    RegExp(r'pluginClass:\s*AoidPasskeyPlugin\b').hasMatch(pubspec);

/// "iOS 16 or macOS 13 at runtime": the native half gates on exactly that.
bool passkeyOsFloorBound({
  required String readme,
  required List<String> darwinSources,
}) =>
    _has(readme, 'iOS 16') &&
    _has(readme, 'macOS 13') &&
    darwinSources
        .map(_stripLineComments)
        .any((s) => s.contains('#available(iOS 16.0, macOS 13.0, *)'));

/// "Your deployment targets do not have to move ... builds down to iOS 13 and
/// macOS 10.15": the podspec AND the SwiftPM manifest both say so.
bool passkeyDeploymentFloorBound({
  required String readme,
  required String podspec,
  required String packageSwift,
}) =>
    _has(readme, 'iOS 13') &&
    _has(readme, 'macOS 10.15') &&
    RegExp(
      r"^\s*s\.ios\.deployment_target\s*=\s*'13\.0'",
      multiLine: true,
    ).hasMatch(podspec) &&
    RegExp(
      r"^\s*s\.osx\.deployment_target\s*=\s*'10\.15'",
      multiLine: true,
    ).hasMatch(podspec) &&
    _stripLineComments(packageSwift).contains('.iOS("13.0")') &&
    _stripLineComments(packageSwift).contains('.macOS("10.15")');

/// "Not provided: hardware security keys": the native half uses the platform
/// provider and never the security-key one.
bool passkeyNoSecurityKeyBound({
  required String readme,
  required List<String> darwinSources,
}) {
  final code = darwinSources.map(_stripLineComments).toList();
  return _has(readme, 'hardware security keys') &&
      // Anchor: the platform provider IS used, so an empty or unrelated
      // source list cannot pass the absence check below vacuously.
      code.any(
        (s) => s.contains('ASAuthorizationPlatformPublicKeyCredentialProvider'),
      ) &&
      code.every((s) => !s.contains('SecurityKeyPublicKeyCredentialProvider'));
}

/// The sentences the README quotes as the form's copy, verbatim in the README
/// AND as a Dart string literal in [source].
bool passkeyCopyBound({
  required String readme,
  required String source,
  required List<String> sentences,
}) {
  final code = _joinAdjacentLiterals(_stripLineComments(source));
  return sentences.isNotEmpty &&
      sentences.every((s) => _hasExact(readme, s) && code.contains("'$s'"));
}

/// The copy the README's outcome table quotes from `AoidLoginForm`.
const List<String> kPasskeyFormCopy = <String>[
  'That did not work. Check your details and try again.',
  'Passkey sign-in is not available on this device right now. '
      'Use your password instead.',
  'Passkey sign-in could not be completed. Use your password instead.',
];

/// The MFA form's dead-end line the "Not provided" list quotes.
const List<String> kMfaWebAuthnCopy = <String>[
  'Use your security key to continue.',
];

/// Every value of the outcome enum has a row in the README's outcome table.
bool passkeyOutcomeTableBound({
  required String readme,
  required Iterable<String> outcomeNames,
}) =>
    outcomeNames.isNotEmpty &&
    outcomeNames.every((name) => _hasExact(readme, '| `$name` |'));

/// Every `.swift` file under `darwin/`.
List<String> _darwinSwiftSources() {
  final dir = Directory('darwin');
  expect(
    dir.existsSync(),
    isTrue,
    reason:
        'MISSING darwin/. The README documents a native half for iOS and '
        'macOS; without the directory every darwin binding below would read '
        'an empty list.',
  );
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.swift'))
      .map((f) => f.readAsStringSync())
      .toList();
}

/// Reads a file the passkey bindings inspect, failing loudly if it moved.
String _passkeySource(String path) {
  final f = File(path);
  expect(
    f.existsSync(),
    isTrue,
    reason:
        'MISSING $path. A passkey binding inspects its TEXT; an absent file '
        'would read as empty.',
  );
  return f.readAsStringSync();
}

const String kPasskeyDartHalf =
    'lib/src/aoid/passkey/aoid_platform_passkey_authenticator.dart';
const String kPasskeyLoginForm = 'lib/src/aoid/widgets/aoid_login_form.dart';
const String kPasskeyMfaForm = 'lib/src/aoid/widgets/aoid_mfa_form.dart';
const String kPasskeyPodspec = 'darwin/eden_platform_flutter.podspec';
const String kPasskeyPackageSwift =
    'darwin/eden_platform_flutter/Package.swift';

void main() {
  // ── item 1 ────────────────────────────────────────────────────────────────
  //
  // FIRST, and deliberately so. Every predicate above runs over a string; a
  // missing file read as '' would fail them all with a confusing message, and
  // — worse — an EMPTY file would pass any predicate written as a negation.
  // This test makes "the README is gone" a distinct, legible failure.
  group('item 1 — the README exists and is substantive', () {
    test('lib/src/aoid/README.md exists', () {
      expect(
        File(kReadmePath).existsSync(),
        isTrue,
        reason:
            'MISSING: $kReadmePath. Every other test in this file inspects '
            'that file\'s TEXT; an absent file reads as empty and would make '
            'their failures unreadable. The AOID SDK ships inside a package '
            'with 18 consumers and no other document describes its modes, its '
            'two entitlement axes, or the tnt trap.',
      );
    });

    test('it is not a stub — at least 9 top-level sections and real prose', () {
      final src = File(kReadmePath).readAsStringSync();
      final sections = RegExp(r'^## ', multiLine: true).allMatches(src).length;
      expect(
        sections,
        greaterThanOrEqualTo(9),
        reason:
            'The README must carry all nine required sections (what the module '
            'is; the three ranked modes; EdenFeatureGate; the two entitlement '
            'axes; the RBAC boundary; the tnt trap; redirect registration; the '
            'web caveats; known limitations). Found $sections `## ` headings. '
            'A README that satisfies the claim predicates without the '
            'structure is a keyword list, not a document.',
      );
      expect(
        src.length,
        greaterThan(4000),
        reason:
            'A file short enough to be a placeholder can still contain every '
            'gated phrase. This floor makes "delete the prose, keep the '
            'keywords" fail.',
      );
    });

    test('fenced code blocks are balanced', () {
      final src = File(kReadmePath).readAsStringSync();
      final fences = RegExp(r'^```', multiLine: true).allMatches(src).length;
      expect(
        fences.isEven,
        isTrue,
        reason:
            'Odd number of ``` fences ($fences): an unclosed code block '
            'swallows the rest of the document in every Markdown renderer, '
            'so the sections below it become invisible while this gate still '
            'sees their text.',
      );
    });
  });

  // ── items 2-8 ─────────────────────────────────────────────────────────────
  group('items 2-8 — the load-bearing claims are present', () {
    late String src;
    setUpAll(() => src = File(kReadmePath).readAsStringSync());

    for (final claim in kClaims) {
      test(claim.name, () {
        expect(claim.holds(src), isTrue, reason: claim.breaks);
      });
    }
  });

  // ── the redirect table must match the SERVER, not just itself ─────────────
  //
  // A gate asserting the README contains `edenbiz://auth` is satisfied by a
  // README that ALSO contains `edenbiz://auth/`. AOID exact-matches, so the
  // trailing-slash variant is a production failure that the presence check
  // cannot see. This asserts the absence of the wrong forms too.
  group('item 8b — no invented trailing slashes on the registered URIs', () {
    late String src;
    setUpAll(() => src = File(kReadmePath).readAsStringSync());

    const registered = <String>[
      'edenbiz://auth',
      'aodex://auth-callback',
      'https://dex.aocyber.ai/auth.html',
    ];

    for (final uri in registered) {
      test('`$uri` never appears with a trailing slash', () {
        expect(
          normalize(src).contains('$uri/'),
          isFalse,
          reason:
              'The README contains `$uri/`. AOID compares redirect URIs by '
              'EXACT STRING (the token service) and '
              'config/oauth-clients.yaml registers `$uri` with NO trailing '
              'slash. A consumer copying the slashed form from this document '
              'gets invalid_request from the authorize endpoint, with no '
              'indication that one character is the cause.',
        );
      });
    }
  });

  // ── THE ANTI-ROT HALF ─────────────────────────────────────────────────────
  //
  // Everything above proves the README still SAYS the right things. That alone
  // makes this file a spellchecker: it fails when someone edits the document
  // and stays green while the CODE the document describes drifts out from
  // under it — which is the failure mode a README actually has.
  //
  // This group binds the document to the source. Every symbol and path the
  // README names must still exist. A rename, a deletion, or a half-applied
  // refactor in `lib/` turns this red WITHOUT ANYONE TOUCHING THE README,
  // which is the property that makes the gate worth having.
  group('anti-rot — the README\'s claims still bind to the source', () {
    late String src;
    setUpAll(() => src = File(kReadmePath).readAsStringSync());

    test('every Dart type the README names still resolves from the ONE '
        'entrypoint', () {
      // These are compile-time references through
      // `package:eden_platform_flutter/eden_platform.dart`. If any type is
      // renamed or dropped from the barrel, THIS FILE FAILS TO COMPILE — a
      // stronger signal than any string match, and it fires on a source edit
      // rather than a doc edit.
      final documented = <String, Object?>{
        // The two tnt types. The README's whole trap section is about these.
        'AoidActiveTenantSlug': const AoidActiveTenantSlug('acme'),
        'AoidHomeTenantId': const AoidHomeTenantId('018f3a2b'),
        // The three deployment modes, by VALUE not by name, so a renamed enum
        // constant is caught too.
        'AoidDeploymentMode.bff': AoidDeploymentMode.bff,
        'AoidDeploymentMode.publicPkce': AoidDeploymentMode.publicPkce,
        'AoidDeploymentMode.sameOrigin': AoidDeploymentMode.sameOrigin,
        // The claim types carrying `ent`.
        'AoidAccessClaims': AoidAccessClaims,
        'AoidIdClaims': AoidIdClaims,
        // Mode A's seam, named in the modes section.
        'AoidCodeSink': AoidCodeSink,
        'HttpBffCodeSink': HttpBffCodeSink,
        // The two retry postures the "Known limitations" table contrasts.
        'AoidRedirectOptions': AoidRedirectOptions,
        'AoidRedirectFlow': AoidRedirectFlow,
        'AoidTenantController': AoidTenantController,
        'AoidTenantDenied': AoidTenantDenied,
        'aoidTenantSwitchRetry': aoidTenantSwitchRetry,
        // The sealed widgets.
        'AoidLoginForm': AoidLoginForm,
        // The passkey section's public names. Members are keyed by their OWN
        // name, so the README check below demands the member, not just the
        // class it hangs on. The outcome enum is bound by VALUE, like the
        // deployment modes, so a renamed constant is caught too.
        'AoidPasskeyOutcome': AoidPasskeyOutcome.cancelled,
        'canUsePasskey': (AoidNativeFlow flow) => flow.canUsePasskey,
        'passkeyLabel': const AoidLoginTheme().passkeyLabel,
      };

      documented.forEach((name, symbol) {
        expect(
          symbol,
          isNotNull,
          reason:
              '$name no longer resolves from eden_platform.dart, but the '
              'README still documents it.',
        );
        // And the README must actually mention it — otherwise this map drifts
        // into a list of symbols nobody documented, and the binding is fake.
        expect(
          _hasExact(src, name.split('.').first),
          isTrue,
          reason:
              'The source still exports ${name.split('.').first}, but the '
              'README no longer names it. Either document it or drop it from '
              'this map — a binding test that checks symbols the document '
              'does not mention proves nothing about the document.',
        );
      });
    });

    test('every lib/ path the README points a reader at still exists', () {
      // The README sends readers to specific files. A moved file makes the
      // document confidently wrong, and nothing else in CI would notice.
      const cited = <String>[
        // The UI-hinting section's subject.
        'lib/src/entitlements/feature_gate.dart',
        // The plan/billing axis, named to keep the two apart.
        'lib/src/entitlements/entitlements_repository.dart',
        // Mode A's contract.
        'lib/src/aoid/mode/aoid_code_sink.dart',
        'lib/src/aoid/mode/http_bff_code_sink.dart',
        // The compile-time proof the tnt section claims exists.
        'test/aoid/claims/no_conflation_compile_gate_test.dart',
        // The repo-wide D6 gate the web-caveats section relies on.
        'test/aoid/no_tokens_in_callback_gate_test.dart',
        // The fold's record.
        'doc/riverpod-3-migration.md',
        // The quickstart the README advertises.
        'example/aoid_quickstart/main.dart',
        // The passkey section: the gate it says keeps the assertion out of
        // the form, and the channel's two halves named under "Debugging the
        // channel".
        'test/aoid/widgets/sealed_form_no_leak_test.dart',
        'lib/src/aoid/passkey/aoid_platform_passkey_authenticator.dart',
        'darwin/eden_platform_flutter/Sources/eden_platform_flutter/'
            'AoidPasskeyPlugin.swift',
      ];

      for (final path in cited) {
        expect(
          File(path).existsSync(),
          isTrue,
          reason:
              'The README points readers at `$path`, which does not exist. '
              'Either the file moved and the README is now confidently wrong, '
              'or it was deleted and the section describing it is obsolete.',
        );
        expect(
          _hasExact(src, path.split('/').last),
          isTrue,
          reason:
              'This test asserts `$path` exists because the README cites it, '
              'but the README no longer mentions it. Drop it from `cited` or '
              'restore the reference.',
        );
      }
    });

    test('the two deleted barrels stay deleted', () {
      // The README states plainly that aoid.dart and aoid_riverpod.dart are
      // gone and must not be re-created. If someone re-creates one, the
      // document's opening section becomes false.
      for (final gone in const ['lib/aoid.dart', 'lib/aoid_riverpod.dart']) {
        expect(
          File(gone).existsSync(),
          isFalse,
          reason:
              '$gone exists again. The README tells every consumer to import '
              'eden_platform.dart and states these barrels were deleted by '
              'the barrel consolidation. A resurrected barrel splits the surface again and makes '
              'the README\'s first section wrong.',
        );
      }
    });
  });

  // ── anti-rot, part 2: BEHAVIOURAL claims ─────────────────────────────────
  //
  // The group above binds NAMES and PATHS. That is necessary and not
  // sufficient: it was FALSIFIED during the migration by a break that left every
  // documented symbol resolving and every cited file in place, while the
  // source silently contradicted the document.
  //
  // The break: giving `AoidRedirectOptions.callbackScheme` a default value of
  // `'edenbiz'`. The README states it is "REQUIRED and has no default" because
  // this package ONCE SHIPPED a hardcoded personal scheme to every consumer.
  // Every test in this file stayed green. That is precisely the drift a README
  // gate exists to catch, and name-resolution cannot see it.
  //
  // So these bind the CONTRACT rather than the identifier. They fire on a
  // source edit with the README untouched.
  group('anti-rot — the README\'s BEHAVIOURAL claims bind to the source', () {
    /// Reads a source file, failing loudly rather than vacuously if it moved.
    String source(String path) {
      final f = File(path);
      expect(
        f.existsSync(),
        isTrue,
        reason:
            'MISSING $path. This predicate inspects that file\'s TEXT; an '
            'absent file would read as empty and pass a negative assertion.',
      );
      return f.readAsStringSync();
    }

    test('`AoidRedirectOptions.callbackScheme` is still REQUIRED with NO '
        'default', () {
      const path = 'lib/src/aoid/flow/aoid_redirect_options.dart';
      final src = source(path);

      // Anchor first: if the constructor is renamed away, the two assertions
      // below would both hold on an unrelated file and prove nothing.
      expect(
        src.contains('AoidRedirectOptions({'),
        isTrue,
        reason:
            'The AoidRedirectOptions constructor is no longer declared in the '
            'shape this test inspects, so the assertions below are unanchored.',
      );
      expect(
        RegExp(r'required\s+this\.callbackScheme\s*,').hasMatch(src),
        isTrue,
        reason:
            'The README states `AoidRedirectOptions.callbackScheme` is '
            'REQUIRED and has no default, and `callbackScheme` is no longer a '
            'required parameter. A shared library CANNOT guess a per-app '
            'bundle identifier: this package previously shipped ONE hardcoded '
            'personal scheme to every consumer, and every app that did not '
            'override it sent its users to somebody else\'s callback.',
      );
      // The complement, and the half that catches the real drift: `required`
      // being present somewhere does not mean a default was not added.
      expect(
        RegExp(r'this\.callbackScheme\s*=').hasMatch(src),
        isFalse,
        reason:
            '`callbackScheme` has been given a DEFAULT VALUE. The README says '
            'it has none, and the default silently re-introduces exactly the '
            'defect the "Redirect URI registration" section documents — a '
            'consumer who never sets it now compiles, ships, and sends its '
            'users to a scheme registered to a different application. AOID '
            'exact-matches redirect URIs, so this fails at the authorize '
            'endpoint with no useful error.',
      );
    });

    test('the TWO RETRY POSTURES are still structurally different — the '
        'README\'s "Known limitations" table describes a real seam', () {
      // The redirect flow returns a SEALED VALUE and never throws, so riverpod
      // 3's automatic retry is structurally unreachable. The tenant switch
      // THROWS, defended by an opt-in policy. The README contrasts them
      // explicitly and calls the sealed form the stronger of the two. If the
      // recorded follow-up
      // converts the tenant switch to a sealed return, THIS TEST GOES RED and
      // the table must be rewritten — which is the intended handoff, not a
      // breakage.

      // Posture 1 — sealed value. `AoidRedirectOutcome` is a sealed supertype,
      // and it is NOT an Exception: there is nothing for a retry to catch.
      expect(
        const AoidRedirectCancelled(),
        isA<AoidRedirectOutcome>(),
        reason:
            'AoidRedirectCancelled is no longer an AoidRedirectOutcome, so '
            'the sealed-return posture the README documents has changed.',
      );
      expect(
        const AoidRedirectCancelled(),
        isNot(isA<Exception>()),
        reason:
            'A redirect outcome is now an Exception. The README states '
            '`AoidRedirectFlow.start()` returns a sealed value for every '
            'EXPECTED outcome and never throws — which is why riverpod\'s '
            '10-attempt / ~38s retry window is structurally unreachable for '
            'every consumer, including ones not yet written. If outcomes can '
            'be thrown, that guarantee is gone and the table is wrong.',
      );
      expect(
        RegExp(r'Future<AoidRedirectOutcome>\s+start\s*\(').hasMatch(
          source('lib/src/aoid/flow/aoid_redirect_flow.dart'),
        ),
        isTrue,
        reason:
            '`start()` no longer returns Future<AoidRedirectOutcome>. The '
            'README\'s retry-posture table names that return type as the '
            'reason riverpod retry cannot engage.',
      );

      // Posture 2 — a throw, defended by an opt-in policy. Deliberately NOT
      // the sealed form: the contract mandated the throw in three places
      // whose gates were already proven.
      expect(
        const AoidTenantDenied(),
        isA<Exception>(),
        reason:
            'AoidTenantDenied is no longer an Exception. The README documents '
            'TWO postures and says the tenant switch THROWS, defended by '
            '`aoidTenantSwitchRetry`. If this became a sealed value, the seam '
            'the table describes has closed — rewrite that table (this is '
            'the recorded follow-up landing), do not delete this test.',
      );
      expect(
        const AoidTenantDenied(),
        isNot(isA<Error>()),
        reason:
            'AoidTenantDenied became an Error. riverpod 3 declines Error and '
            'retries every ordinary Exception — that asymmetry is the entire '
            'reason `aoidTenantSwitchRetry` exists. Making it an Error would '
            'silently make the policy redundant and the README misleading.',
      );
      expect(
        aoidTenantSwitchRetry(0, const AoidTenantDenied()),
        isNull,
        reason:
            '`aoidTenantSwitchRetry` no longer DECLINES to retry a denial. A '
            'tenant denial is a permission answer, not a transient fault: '
            'retrying it re-asks a question already answered, and the README '
            'presents this policy as the defence that makes the throwing '
            'posture safe.',
      );
      expect(
        RegExp(r'Future<AoidActiveTenantSlug>\s+switchTo\s*\(').hasMatch(
          source('lib/src/aoid/tenant/aoid_tenant_controller.dart'),
        ),
        isTrue,
        reason:
            '`AoidTenantController.switchTo` no longer returns a bare '
            'Future<AoidActiveTenantSlug>. The README contrasts this with '
            '`start()`\'s sealed return; if switchTo now returns a sealed '
            'result, the two postures have converged and the table is stale.',
      );
    });

    test('SDK-07 stays OPEN — no authenticated "list my tenants" surface has '
        'appeared', () {
      // The README states plainly that this SDK can PERFORM a switch but
      // cannot POPULATE a picker, because AOID has no authenticated tenant-list
      // RPC. If one is added, the "Known limitations" entry becomes false — and
      // a stale limitation is worse than none, because a reader who works
      // around it is doing unnecessary work.
      final controller = source(
        'lib/src/aoid/tenant/aoid_tenant_controller.dart',
      );
      expect(
        RegExp(
          r'(listTenants|availableTenants|myTenants|tenantList)',
        ).hasMatch(controller),
        isFalse,
        reason:
            'Something tenant-LIST shaped now exists on the tenant controller. '
            'The README\'s SDK-07 entry says the host application must supply '
            'the list because AOID exposes no authenticated way to fetch it '
            '(ResolveWorkspacesByEmail is pre-login and enumeration-safe, '
            'ListTenants is an admin surface, ResolveMembership resolves '
            'exactly one). If that changed, close SDK-07 in the README.',
      );
    });
  });

  // ── item 9 — THE POSITIVE CONTROL ────────────────────────────────────────
  //
  // Without this, every test above passes whenever its predicate is broken,
  // and the whole file certifies nothing. Each claim is run against a fixture
  // built by DELETING that claim from the real README, and must REJECT it.
  //
  // Note the fixture is derived from the real file rather than hand-written:
  // a hand-written fixture drifts, and then item 9 proves the predicates work
  // on a document nobody ships.
  group('item 9 — the gate can fail', () {
    late String real;
    setUpAll(() => real = File(kReadmePath).readAsStringSync());

    test('the predicates accept the real README (non-vacuity floor)', () {
      // If this fails, item 9's rejections below could be passing because the
      // predicates reject EVERYTHING, which is not the property under test.
      for (final claim in kClaims) {
        expect(
          claim.holds(real),
          isTrue,
          reason:
              '${claim.name} does not hold on the real README, so the '
              'rejection tests below prove nothing about it.',
        );
      }
    });

    // Each entry names a token whose removal must break exactly the claim that
    // depends on it. These are the SUBSTANTIVE anchors, not incidental words.
    const mutilations = <String, List<String>>{
      'item 2': ['UI hinting', 'EdenFeatureGate'],
      'item 3': ['entitlements/bootstrap', 'identity_memberships'],
      'item 4': ['publicPkce', 'forbidden'],
      'item 5': ['shipped until'],
      'item 6': ['AoidActiveTenantSlug', 'AoidHomeTenantId'],
      'item 7': ['owns authZ'],
      'item 8': ['aodex://auth-callback', 'edenbiz://auth'],
      'item 10': [
        'webcredentials:',
        'apple-app-site-association',
        'Release.entitlements',
        'provisioning profile',
        'iOS 16',
        'pod install',
      ],
      'item 11': [
        'not available on this device right now',
        'stays on the password',
        'no button',
      ],
      // Mutilation tokens are deleted from the RAW text, so each must sit on
      // one README line; 'treats both' is the unwrapped head of the phrase.
      'item 12': ['same cancellation', 'treats both'],
      'item 13': [
        'hosted sign-in page',
        'Credential Manager',
        'hardware security keys',
        'second-factor step',
        'omitted',
      ],
      'item 14': [
        'eden_platform_flutter/aoid_passkey',
        'MissingPluginException',
      ],
    };

    mutilations.forEach((itemKey, tokens) {
      for (final token in tokens) {
        test('removing "$token" is REJECTED by $itemKey', () {
          final claim = kClaims.firstWhere((c) => c.name.startsWith(itemKey));
          // Case-insensitive removal, because two predicates match
          // case-insensitively and a case-sensitive delete would leave a
          // variant behind and read as a false "the gate cannot fail".
          final mutilated = real.replaceAll(
            RegExp(RegExp.escape(token), caseSensitive: false),
            'REDACTED',
          );
          expect(
            mutilated == real,
            isFalse,
            reason:
                'The mutilation was a NO-OP — "$token" is not in the README, '
                'so this test would "pass" without exercising anything. That '
                'is how a positive control silently stops controlling.',
          );
          expect(
            claim.holds(mutilated),
            isFalse,
            reason:
                '$itemKey still holds after "$token" was removed from the '
                'README. The predicate is therefore NOT gating that claim: '
                'someone could delete it and CI would stay green. Tighten the '
                'predicate — do not delete this control.',
          );
        });
      }
    });

    test('an empty document is rejected by every claim', () {
      // The vacuous-pass case: a predicate written as a negation would accept
      // ''. None here are, and this proves it rather than asserting it.
      for (final claim in kClaims) {
        expect(
          claim.holds(''),
          isFalse,
          reason:
              '${claim.name} holds on an EMPTY string. That predicate would '
              'certify a deleted README.',
        );
      }
    });
  });

  // ── item 15 — the passkey section binds to the SOURCE ────────────────────
  //
  // Items 10-14 fail when the README drifts. These fail when the CODE drifts
  // with the README untouched: a renamed channel, a new platform in the
  // pubspec, a raised OS gate, a security-key provider, a reworded sentence,
  // a new outcome value.
  group('item 15 — the passkey section\'s claims bind to the source', () {
    late String readme;
    setUpAll(() => readme = File(kReadmePath).readAsStringSync());

    test('the channel `$kPasskeyChannel` is declared in code by BOTH halves '
        '(darwin/ and the Dart half), and the README names it', () {
      expect(
        passkeyChannelBound(
          readme: readme,
          dartHalf: _passkeySource(kPasskeyDartHalf),
          darwinSources: _darwinSwiftSources(),
        ),
        isTrue,
        reason:
            'The channel name no longer matches across the README, '
            '$kPasskeyDartHalf and darwin/. A rename on one side compiles on '
            'both and fails only at runtime: the Dart half gets a '
            'MissingPluginException, reads it as "not supported", and the '
            'button silently disappears on every iOS and macOS app. The README '
            'names the channel so that symptom can be traced; a wrong name '
            'there sends the reader after a channel that does not exist.',
      );
    });

    test('the plugin is declared for iOS and macOS ONLY, registering '
        'AoidPasskeyPlugin', () {
      final pubspec = _passkeySource('pubspec.yaml');
      expect(
        passkeyPlatformsBound(readme: readme, pubspec: pubspec),
        isTrue,
        reason:
            'pubspec.yaml now declares plugin platforms '
            '${declaredPluginPlatforms(pubspec)}. The README promises web, '
            'Android, Windows and Linux builds are unchanged and that Android '
            'is not provided. A platform added here registers a plugin in '
            'every consumer of this shared library on that platform.',
      );
    });

    test('the native half gates on iOS 16 / macOS 13 at runtime', () {
      expect(
        passkeyOsFloorBound(
          readme: readme,
          darwinSources: _darwinSwiftSources(),
        ),
        isTrue,
        reason:
            'The README tells consumers the button appears on iOS 16+ and '
            'macOS 13+, and darwin/ no longer gates on '
            '`#available(iOS 16.0, macOS 13.0, *)`. Either the gate moved and '
            'the README misstates who gets the button, or it was dropped and '
            'an older OS reaches an API it does not have.',
      );
    });

    test('the deployment floors the README promises (iOS 13 / macOS 10.15) '
        'are what the podspec and Package.swift declare', () {
      expect(
        passkeyDeploymentFloorBound(
          readme: readme,
          podspec: _passkeySource(kPasskeyPodspec),
          packageSwift: _passkeySource(kPasskeyPackageSwift),
        ),
        isTrue,
        reason:
            'The README says consumers do not have to raise their deployment '
            'targets because the native half builds down to iOS 13 and macOS '
            '10.15. If the podspec or Package.swift raised a floor, every app '
            'below it fails `pod install` / SwiftPM resolution after the bump, '
            'and the README told them it would not.',
      );
    });

    test('hardware security keys are NOT used: platform provider only', () {
      expect(
        passkeyNoSecurityKeyBound(
          readme: readme,
          darwinSources: _darwinSwiftSources(),
        ),
        isTrue,
        reason:
            'darwin/ now references the security-key credential provider (or '
            'no longer references the platform one). The README lists '
            'hardware security keys as NOT provided; update it together with '
            'the code, or remove the provider.',
      );
    });

    test('the sentences the README quotes are the form\'s own copy, byte for '
        'byte', () {
      expect(
        passkeyCopyBound(
          readme: readme,
          source: _passkeySource(kPasskeyLoginForm),
          sentences: kPasskeyFormCopy,
        ),
        isTrue,
        reason:
            'A sentence the README quotes from AoidLoginForm is no longer the '
            'form\'s copy (or no longer in the README). A consumer matching a '
            'user\'s report against the README\'s table would then find no '
            'row for what the user actually saw.',
      );
      expect(
        passkeyCopyBound(
          readme: readme,
          source: _passkeySource(kPasskeyMfaForm),
          sentences: kMfaWebAuthnCopy,
        ),
        isTrue,
        reason:
            'The "Not provided" list quotes AoidMfaForm\'s dead-end line for '
            'the WebAuthn factors, and the form no longer says it.',
      );
    });

    test('every AoidPasskeyOutcome value has a row in the README\'s outcome '
        'table', () {
      expect(
        passkeyOutcomeTableBound(
          readme: readme,
          outcomeNames: AoidPasskeyOutcome.values.map((v) => v.name),
        ),
        isTrue,
        reason:
            'AoidPasskeyOutcome has a value with no `| `name` |` row in the '
            'README. The table is the only description of what each outcome '
            'shows; a new value without a row is behaviour nobody documented.',
      );
    });
  });

  // ── item 16 — the passkey bindings can fail ──────────────────────────────
  //
  // Item 9 for item 15. Each binding is fed the REAL inputs with one thing
  // broken, built from the real files rather than hand-written, and must
  // reject it. Every mutation is first checked to have changed something, so
  // a no-op cannot pass as a rejection.
  group('item 16 — the passkey bindings can fail', () {
    late String readme;
    late String dartHalf;
    late List<String> darwin;
    late String pubspec;
    late String podspec;
    late String packageSwift;
    late String loginForm;
    late String mfaForm;

    setUpAll(() {
      readme = File(kReadmePath).readAsStringSync();
      dartHalf = File(kPasskeyDartHalf).readAsStringSync();
      darwin = _darwinSwiftSources();
      pubspec = File('pubspec.yaml').readAsStringSync();
      podspec = File(kPasskeyPodspec).readAsStringSync();
      packageSwift = File(kPasskeyPackageSwift).readAsStringSync();
      loginForm = File(kPasskeyLoginForm).readAsStringSync();
      mfaForm = File(kPasskeyMfaForm).readAsStringSync();
    });

    /// Applies [mutate] and fails if it changed nothing.
    String mutated(String original, String Function(String) mutate) {
      final out = mutate(original);
      expect(
        out == original,
        isFalse,
        reason:
            'The mutation was a NO-OP, so the rejection below would exercise '
            'nothing. The source it targets has changed shape; rebuild the '
            'mutation against the current file.',
      );
      return out;
    }

    test('non-vacuity floor: every binding accepts the real inputs', () {
      expect(
        passkeyChannelBound(
          readme: readme,
          dartHalf: dartHalf,
          darwinSources: darwin,
        ),
        isTrue,
      );
      expect(passkeyPlatformsBound(readme: readme, pubspec: pubspec), isTrue);
      expect(
        passkeyOsFloorBound(readme: readme, darwinSources: darwin),
        isTrue,
      );
      expect(
        passkeyDeploymentFloorBound(
          readme: readme,
          podspec: podspec,
          packageSwift: packageSwift,
        ),
        isTrue,
      );
      expect(
        passkeyNoSecurityKeyBound(readme: readme, darwinSources: darwin),
        isTrue,
      );
      expect(
        passkeyCopyBound(
          readme: readme,
          source: loginForm,
          sentences: kPasskeyFormCopy,
        ),
        isTrue,
      );
      expect(
        passkeyCopyBound(
          readme: readme,
          source: mfaForm,
          sentences: kMfaWebAuthnCopy,
        ),
        isTrue,
      );
      expect(
        passkeyOutcomeTableBound(
          readme: readme,
          outcomeNames: AoidPasskeyOutcome.values.map((v) => v.name),
        ),
        isTrue,
      );
    });

    group('channel', () {
      test('renamed in the Dart DECLARATION (header comment left intact) is '
          'rejected', () {
        final broken = mutated(
          dartHalf,
          (s) => s.replaceAll(
            RegExp(
              "=\\s*MethodChannel\\(\\s*'${RegExp.escape(kPasskeyChannel)}'",
            ),
            "= MethodChannel('eden_platform_flutter/renamed'",
          ),
        );
        // The comment still quotes the old name: the binding must not be
        // satisfied by it.
        expect(broken.contains("'$kPasskeyChannel'"), isTrue);
        expect(
          passkeyChannelBound(
            readme: readme,
            dartHalf: broken,
            darwinSources: darwin,
          ),
          isFalse,
        );
      });

      test('renamed in Swift (old name left in a comment) is rejected', () {
        final broken = darwin
            .map(
              (s) => s.replaceAll(
                '"$kPasskeyChannel"',
                '"eden_platform_flutter/renamed" // was "$kPasskeyChannel"',
              ),
            )
            .toList();
        expect(
          broken.join() == darwin.join(),
          isFalse,
          reason: 'no Swift file declared "$kPasskeyChannel"; no-op mutation',
        );
        expect(
          passkeyChannelBound(
            readme: readme,
            dartHalf: dartHalf,
            darwinSources: broken,
          ),
          isFalse,
        );
      });

      test('dropped from the README is rejected', () {
        expect(
          passkeyChannelBound(
            readme: mutated(
              readme,
              (s) => s.replaceAll(kPasskeyChannel, 'REDACTED'),
            ),
            dartHalf: dartHalf,
            darwinSources: darwin,
          ),
          isFalse,
        );
      });
    });

    group('platforms', () {
      for (final extra in const ['android', 'web', 'linux', 'windows']) {
        test('an `$extra:` platform in the plugin block is rejected', () {
          final broken = mutated(
            pubspec,
            (s) => s.replaceFirst(
              RegExp(r'^    platforms:\s*\n', multiLine: true),
              '    platforms:\n'
              '      $extra:\n'
              '        pluginClass: AoidPasskeyPlugin\n',
            ),
          );
          expect(declaredPluginPlatforms(broken), contains(extra));
          expect(
            passkeyPlatformsBound(readme: readme, pubspec: broken),
            isFalse,
          );
        });
      }

      test('a pubspec with no plugin block is rejected', () {
        final broken = mutated(
          pubspec,
          (s) => s.replaceFirst(
            RegExp(r'^  plugin:\s*$', multiLine: true),
            '  not_a_plugin:',
          ),
        );
        expect(declaredPluginPlatforms(broken), isEmpty);
        expect(passkeyPlatformsBound(readme: readme, pubspec: broken), isFalse);
      });

      test('a README that drops "declared for iOS and macOS only" is '
          'rejected', () {
        expect(
          passkeyPlatformsBound(
            readme: mutated(
              readme,
              (s) => s.replaceAll(
                RegExp(r'declared\s+for\s+iOS\s+and\s+macOS\s+only'),
                'REDACTED',
              ),
            ),
            pubspec: pubspec,
          ),
          isFalse,
        );
      });
    });

    test('a raised OS gate in Swift is rejected', () {
      final broken = darwin
          .map(
            (s) => s.replaceAll(
              '#available(iOS 16.0, macOS 13.0, *)',
              '#available(iOS 17.0, macOS 14.0, *)',
            ),
          )
          .toList();
      expect(broken.join() == darwin.join(), isFalse);
      expect(
        passkeyOsFloorBound(readme: readme, darwinSources: broken),
        isFalse,
      );
    });

    test('a raised podspec floor, and a raised SwiftPM floor, are each '
        'rejected', () {
      expect(
        passkeyDeploymentFloorBound(
          readme: readme,
          podspec: mutated(podspec, (s) => s.replaceAll("'13.0'", "'15.0'")),
          packageSwift: packageSwift,
        ),
        isFalse,
      );
      expect(
        passkeyDeploymentFloorBound(
          readme: readme,
          podspec: podspec,
          packageSwift: mutated(
            packageSwift,
            (s) => s.replaceAll('.macOS("10.15")', '.macOS("12.0")'),
          ),
        ),
        isFalse,
      );
    });

    test('a security-key provider in Swift is rejected, and so is a source '
        'set with no platform provider at all', () {
      expect(
        passkeyNoSecurityKeyBound(
          readme: readme,
          darwinSources: [
            ...darwin,
            'let p = ASAuthorizationSecurityKeyPublicKeyCredentialProvider('
                'relyingPartyIdentifier: "example.com")',
          ],
        ),
        isFalse,
      );
      expect(
        passkeyNoSecurityKeyBound(readme: readme, darwinSources: const []),
        isFalse,
      );
    });

    test('a reworded form sentence is rejected, and so is an empty sentence '
        'list', () {
      expect(
        passkeyCopyBound(
          readme: readme,
          source: mutated(
            loginForm,
            (s) => s.replaceAll(
              'could not be completed. Use your password instead.',
              'failed. Use your password instead.',
            ),
          ),
          sentences: kPasskeyFormCopy,
        ),
        isFalse,
      );
      // The sentence surviving only in a comment does not count.
      expect(
        passkeyCopyBound(
          readme: readme,
          source: '// \'${kMfaWebAuthnCopy.single}\'',
          sentences: kMfaWebAuthnCopy,
        ),
        isFalse,
      );
      expect(
        passkeyCopyBound(readme: readme, source: loginForm, sentences: []),
        isFalse,
      );
    });

    test('a new outcome value with no README row is rejected, and so is a '
        'README missing an existing row', () {
      final names = AoidPasskeyOutcome.values.map((v) => v.name).toList();
      expect(
        passkeyOutcomeTableBound(
          readme: readme,
          outcomeNames: [...names, 'deferred'],
        ),
        isFalse,
      );
      expect(
        passkeyOutcomeTableBound(
          readme: mutated(
            readme,
            (s) => s.replaceAll('| `interrupted` |', '| interrupted |'),
          ),
          outcomeNames: names,
        ),
        isFalse,
      );
    });
  });
}
