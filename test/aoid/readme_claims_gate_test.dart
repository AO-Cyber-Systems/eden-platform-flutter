// ANTI-ROT GATE for lib/src/aoid/README.md (AOID objective 50, TRD 50-14).
//
// The README documents an SDK that eighteen packages depend on, and two of its
// claims exist because both have ALREADY caused real confusion in this
// codebase (50-CONTEXT.md names them as explicit documentation requirements):
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
// Objective 50 has now found the same defect in nine TRDs: `grep -c "PHRASE"`
// cannot tell which declaration it matched, survives the phrase drifting into
// a comment, and passes vacuously when the file is missing. So the claims are
// named predicates over the file's text, shared between the real README (items
// 2-8) and a deliberately-mutilated fixture (item 9). If a predicate cannot
// reject a README with the claim removed, it is not a gate, and item 9 is what
// proves each one can.

import 'dart:io';

// The ONE entrypoint the README tells consumers to use. Importing it here is
// itself an assertion: if the fold that 50-24 performed is ever half-reverted,
// this file stops compiling and takes the whole gate with it.
import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_test/flutter_test.dart';

/// The path is relative to the package root, which is `flutter test`'s cwd.
const String kReadmePath = 'lib/src/aoid/README.md';

/// A load-bearing claim: a name, a predicate, and what breaks without it.
typedef ReadmeClaim = ({String name, bool Function(String) holds, String breaks});

/// Collapses whitespace so a claim cannot be broken by a line wrap.
///
/// This is not cosmetic. TRD 50-03 lost a doc gate to exactly this: the prose
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

/// The claims, in the order the TRD's test list names them (items 2-8).
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
        '50-CONTEXT.md names this as a required doc item BECAUSE IT HAS '
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
        'word. 50-CONTEXT.md names this as a required doc item BECAUSE IT HAS '
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
        // is accepted by construction (50-12).
        _has(src, 'refresh token'),
    breaks: 'Without this, a consumer picks a mode by guessing, and the '
        'fourth option — a refresh token in web localStorage — looks like a '
        'convenient way to survive a page reload. It is durably readable by '
        'any XSS. D4 forbids it and 50-02 removed the CAPABILITY at four '
        'separate write paths; this section is the only thing telling a '
        'consumer not to rebuild it in their own app.',
  ),
  (
    name: 'item 5 — the forbidden posture SHIPPED until objective 50 (the '
        'history, not just the rule)',
    holds: (src) => _has(src, 'shipped until'),
    breaks: 'THIS IS THE SINGLE MOST USEFUL SENTENCE IN THE DOCUMENT for a '
        'future reader deciding whether the storage restriction is real. A '
        'rule with no history reads as caution and gets traded away the first '
        'time someone hits a storage failure on web. A rule that says "this '
        'is what we actually shipped, to real users, until objective 50" does '
        'not. 50-02 measured it: four write paths, one of which nobody knew '
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
    breaks: 'AOID EXACT-MATCHES redirect URIs (internal/oauth/service.go:457). '
        'A consumer that invents a trailing slash, or types `aodex://auth` '
        'instead of `aodex://auth-callback`, gets a rejected authorize request '
        'and no useful error. This table is the only place a consumer can '
        'read the registered values without reverse-engineering '
        'config/oauth-clients.yaml.',
  ),
];

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
              'EXACT STRING (internal/oauth/service.go:457) and '
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
              '50-24. A resurrected barrel splits the surface again and makes '
              'the README\'s first section wrong.',
        );
      }
    });
  });

  // ── anti-rot, part 2: BEHAVIOURAL claims ─────────────────────────────────
  //
  // The group above binds NAMES and PATHS. That is necessary and not
  // sufficient: it was FALSIFIED during 50-14 by a break that left every
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
      // 50-12 returns a SEALED VALUE and never throws, so riverpod 3's
      // automatic retry is structurally unreachable. 50-13 THROWS, defended by
      // an opt-in policy. The README contrasts them explicitly and calls the
      // sealed form the stronger of the two. If 50-15's recorded follow-up
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
      // the sealed form: 50-13's contract mandated the throw in three places
      // whose gates were already proven.
      expect(
        const AoidTenantDenied(),
        isA<Exception>(),
        reason:
            'AoidTenantDenied is no longer an Exception. The README documents '
            'TWO postures and says the tenant switch THROWS, defended by '
            '`aoidTenantSwitchRetry`. If this became a sealed value, the seam '
            'the table describes has closed — rewrite that table (this is '
            '50-15\'s recorded follow-up landing), do not delete this test.',
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
}
