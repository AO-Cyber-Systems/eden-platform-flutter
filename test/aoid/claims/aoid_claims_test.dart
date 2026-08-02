// TRD 50-03 test-list items 4-8 — the two unverified decoders, and the
// EMPIRICAL half of the `tnt` proof.
//
// The type-level proof (conflation is a compile error) lives in
// no_conflation_compile_gate_test.dart. This file proves the SEMANTICS the
// types encode are the ones AOID actually ships: that the value arriving on the
// access token really is a slug and the one on the id_token really is a UUID,
// for one identity at one moment.

import 'dart:io';

import 'package:eden_platform_flutter/aoid.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/aoid_claim_fixtures.dart' as fx;

const _sourcePath = 'lib/src/aoid/claims/aoid_claims.dart';

/// Strips `///` markers and collapses runs of whitespace to single spaces.
///
/// Load-bearing: a doc comment reflows across line breaks the moment it is
/// edited, so a phrase assertion made against the raw text is a coin flip.
/// TRD 50-04 hit exactly this — its "MUST replace their stored handle" gate
/// would have returned 0 purely because the phrase had wrapped.
String _normalizeDoc(String raw) => raw
    .split('\n')
    .map((l) => l.trimLeft().startsWith('///') ? l.trimLeft().substring(3) : l)
    .join(' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// The doc comment attached to [declaration], normalized, and nothing else.
///
/// Scoped on purpose. A file-wide `grep -c "UI HINTING ONLY"` cannot tell WHICH
/// declaration it matched — TRD 50-04's `TELEMETRY ONLY` gate passed while the
/// comment sat on the wrong class. A doctrine warning that has drifted off the
/// thing it warns about is worse than absent, because it reads as covered.
String _docCommentOn(String declaration) {
  final src = File(_sourcePath).readAsStringSync();
  final at = src.indexOf(declaration);
  expect(
    at,
    isNonNegative,
    reason: 'no declaration matching `$declaration` in $_sourcePath',
  );
  return _normalizeDoc(_precedingDocLines(src, at));
}

/// The contiguous run of `///` lines immediately preceding [offset].
String _precedingDocLines(String src, int offset) {
  final before = src.substring(0, offset).split('\n');
  var first = before.length - 1;
  while (first > 0 && before[first - 1].trimLeft().startsWith('///')) {
    first--;
  }
  return before.sublist(first).join('\n');
}

/// RFC 4122 8-4-4-4-12 hex. Used as an empirical shape check on the two `tnt`
/// values — the id_token's must match, the access token's must not.
final _uuidRe = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

void main() {
  group('AoidAccessClaims.decodeUnverified', () {
    // Item 4
    test('yields every access-token claim, with tnt typed as the ACTIVE '
        'tenant slug', () {
      final claims = AoidAccessClaims.decodeUnverified(
        fx.accessTokenSwitchedToTenantB,
      );

      // The static type here is the assertion: this line would not compile if
      // `activeTenant` were a String or an AoidHomeTenantId.
      final AoidActiveTenantSlug active = claims.activeTenant;
      expect(active.slug, fx.tenantBSlug);

      expect(claims.subject, fx.identitySubject);
      expect(claims.entitlements, ['tenant.admin', 'aodex.user']);
      expect(claims.aal, 'aal2');
      expect(claims.clientId, fx.clientId);
      expect(
        claims.expiresAt,
        DateTime.fromMillisecondsSinceEpoch(
          fx.expEpochSeconds * 1000,
          isUtc: true,
        ),
      );
      expect(claims.expiresAt.isUtc, isTrue);
    });

    test('omitted `aal` and `ent` decode to null and an empty list, because Go '
        'marks both omitempty', () {
      final claims = AoidAccessClaims.decodeUnverified(
        fx.accessTokenWithoutOptionalClaims,
      );
      expect(claims.aal, isNull);
      expect(claims.entitlements, isEmpty);
      expect(claims.activeTenant.slug, fx.homeTenantSlug);
    });

    test('an ID token handed to the ACCESS decoder is rejected, not silently '
        'mis-decoded', () {
      // Runtime backstop for the case the type system cannot see: the caller
      // passes the wrong token. The id_token has no client_id, so the decode
      // fails rather than producing an AoidActiveTenantSlug holding a UUID.
      Object? thrown;
      try {
        AoidAccessClaims.decodeUnverified(fx.idTokenHomeTenant);
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<AoidClaimsFormatException>());
      // Pin WHY it was rejected. Without this the test would still pass if the
      // decode failed for some incidental reason, and would prove nothing about
      // the wrong-token case.
      expect(
        thrown.toString(),
        contains('client_id'),
        reason:
            'the id_token must be rejected because it carries no client_id — '
            'if it is being rejected for another reason this test is not '
            'proving what it claims',
      );
    });
  });

  group('AoidIdClaims.decodeUnverified', () {
    // Item 5
    test('yields every id-token claim, with tnt typed as the HOME tenant '
        'uuid', () {
      final claims = AoidIdClaims.decodeUnverified(fx.idTokenHomeTenant);

      // Static type is the assertion, as above.
      final AoidHomeTenantId home = claims.homeTenant;
      expect(home.uuid, fx.homeTenantUuid);

      expect(claims.subject, fx.identitySubject);
      expect(claims.email, 'ada@acme.example');
      expect(claims.emailVerified, isTrue);
    });

    test('omitted profile claims decode to null / false', () {
      final claims = AoidIdClaims.decodeUnverified(
        fx.idTokenWithoutProfileClaims,
      );
      expect(claims.email, isNull);
      expect(claims.emailVerified, isFalse);
      expect(claims.homeTenant.uuid, fx.homeTenantUuid);
    });
  });

  group(
    'the semantic pair — one identity, one moment, two meanings of tnt',
    () {
      // Item 6 — the empirical wrong-tenant / cross-tenant proof.
      test('with an active-tenant switch applied, the access token carries '
          "tenant B's SLUG while the id_token still carries the HOME UUID", () {
        final access = AoidAccessClaims.decodeUnverified(
          fx.accessTokenSwitchedToTenantB,
        );
        final id = AoidIdClaims.decodeUnverified(fx.idTokenHomeTenant);

        // Same identity — this is one user, not two.
        expect(
          access.subject,
          id.subject,
          reason: 'the pair only proves anything if it is the same sub',
        );

        // The access token followed the switch.
        expect(access.activeTenant.slug, fx.tenantBSlug);
        // The id_token did NOT.
        expect(id.homeTenant.uuid, fx.homeTenantUuid);

        // They are different strings...
        expect(access.activeTenant.slug, isNot(id.homeTenant.uuid));

        // ...and different in KIND, which is the durable claim. Shape, not just
        // inequality: a slug is not a UUID.
        expect(
          _uuidRe.hasMatch(id.homeTenant.uuid),
          isTrue,
          reason: "the id_token's tnt must parse as a UUID",
        );
        expect(
          _uuidRe.hasMatch(access.activeTenant.slug),
          isFalse,
          reason: "the access token's tnt must NOT be a UUID",
        );

        // The switch target's UUID never appears on either token.
        expect(access.activeTenant.slug, isNot(fx.tenantBUuid));
        expect(id.homeTenant.uuid, isNot(fx.tenantBUuid));
      });

      // Item 7 — the case that stops item 6 being over-read.
      test('with NO active tenant selected, the access token carries the HOME '
          "tenant's SLUG — equal in identity to the id_token's tenant, but "
          'still not its UUID (GID-14)', () {
        final access = AoidAccessClaims.decodeUnverified(
          fx.accessTokenNoActiveSelection,
        );
        final id = AoidIdClaims.decodeUnverified(fx.idTokenHomeTenant);

        // Both now refer to the SAME tenant. `activeTenant != homeTenant` is
        // therefore NOT a universal invariant — it holds only after a switch.
        expect(access.activeTenant.slug, fx.homeTenantSlug);

        // Even here the two claim VALUES differ, because one is a slug and the
        // other a UUID. That is the invariant that always holds.
        expect(access.activeTenant.slug, isNot(id.homeTenant.uuid));
        expect(_uuidRe.hasMatch(access.activeTenant.slug), isFalse);
        expect(_uuidRe.hasMatch(id.homeTenant.uuid), isTrue);
      });
    },
  );

  group('malformed input fails closed and leaks nothing', () {
    // Item 8
    for (final entry in <String, String>{
      'an unparseable payload segment': 'malformed',
      'a string that is not a JWT at all': 'notAJwt',
    }.entries) {
      test('${entry.key}: throws AoidClaimsFormatException carrying NO token '
          'material', () {
        final token = entry.value == 'malformed'
            ? fx.malformedToken
            : fx.notAJwtAtAll;

        Object? thrown;
        try {
          AoidAccessClaims.decodeUnverified(token);
        } catch (e) {
          thrown = e;
        }

        expect(
          thrown,
          isA<AoidClaimsFormatException>(),
          reason: 'a typed error, not whatever the JWT library threw',
        );

        final rendered = thrown.toString();
        expect(
          rendered,
          isNot(contains(fx.secretMarker)),
          reason:
              'the error message embeds token material. The base64 decoder '
              'under JWT.decode throws a FormatException that QUOTES its '
              'input, and JWTUndefinedException wraps ex.toString() verbatim '
              '— so rethrowing or interpolating the cause leaks token bytes '
              'into every log sink. Build the message from literals only.\n'
              'Message was: $rendered',
        );
        expect(
          rendered,
          isNot(contains(token)),
          reason: 'the error message embeds the whole token',
        );
        // Still has to be useful.
        expect(rendered, contains('AoidClaimsFormatException'));
      });
    }

    test('the id decoder leaks nothing either', () {
      Object? thrown;
      try {
        AoidIdClaims.decodeUnverified(fx.malformedToken);
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<AoidClaimsFormatException>());
      expect(thrown.toString(), isNot(contains(fx.secretMarker)));
    });

    test('a well-formed JWT missing `tnt` is rejected and the message names '
        'the claim, not its value', () {
      Object? thrown;
      try {
        AoidAccessClaims.decodeUnverified(fx.accessTokenMissingTenantClaim);
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<AoidClaimsFormatException>());
      expect(thrown.toString(), contains('tnt'));
      expect(thrown.toString(), isNot(contains(fx.identitySubject)));
    });

    test('a `tnt` of the wrong JSON type is rejected rather than coerced', () {
      // Coercing 42 to "42" would produce an AoidActiveTenantSlug that is not a
      // slug — precisely the class of silent wrongness this TRD exists to stop.
      expect(
        () => AoidAccessClaims.decodeUnverified(
          fx.accessTokenWithNonStringTenant,
        ),
        throwsA(isA<AoidClaimsFormatException>()),
      );
    });
  });

  group('doctrine, pinned to the declaration it is about', () {
    for (final cls in ['AoidAccessClaims', 'AoidIdClaims']) {
      test('$cls says UNVERIFIED / UI HINTING ONLY / server re-verifies', () {
        final doc = _docCommentOn('final class $cls {');
        expect(doc, contains('UNVERIFIED'));
        expect(
          doc,
          contains('UI HINTING ONLY'),
          reason:
              'the doctrine must sit on $cls itself. A file-wide grep would '
              'still pass with this warning parked on the other class, which '
              'is exactly the failure mode TRD 50-04 hit.',
        );
        expect(doc, contains('re-verifies'));
        expect(
          doc,
          contains('aoidverify'),
          reason: 'name where verification actually happens',
        );
        expect(
          doc,
          contains('EdenFeatureGate'),
          reason: 'tie it to the existing doctrine the org already has',
        );
      });

      test('$cls.decodeUnverified is named so no caller can mistake what it '
          'returned', () {
        final src = File(_sourcePath).readAsStringSync();
        final classAt = src.indexOf('final class $cls {');
        // Scope to this class body only, so one correctly-named decoder
        // cannot cover for a renamed sibling.
        final nextClass = src.indexOf('final class ', classAt + 1);
        final body = src.substring(
          classAt,
          nextClass == -1 ? src.length : nextClass,
        );
        expect(
          body,
          contains('static $cls decodeUnverified(String jwt)'),
          reason: '$cls must expose decodeUnverified, not decode',
        );
      });
    }

    test('the ent-vs-eden-biz warning sits ON the entitlements field, where '
        'the mistake would be made', () {
      final doc = _docCommentOn('final List<String> entitlements;');
      expect(
        doc,
        contains('entitlements/bootstrap'),
        reason:
            'AOID `ent` is identity/role; eden-biz '
            '/api/v1/entitlements/bootstrap is plan/billing. Same word, '
            'unrelated systems. This warning belongs on the field, not only '
            'in a README — a file-wide grep would pass with it anywhere.',
      );
      expect(doc, contains('identity/role'));
      expect(doc, contains('NOT the eden-biz'));
    });

    test('subject is documented as GLOBAL, not tenant-scoped, on BOTH claim '
        'sets', () {
      final src = File(_sourcePath).readAsStringSync();
      expect(
        'final String subject;'.allMatches(src).length,
        2,
        reason: 'expected exactly one `subject` field per claim set',
      );
      // Both doc comments must say GID-13 / global.
      var from = 0;
      var checked = 0;
      while (true) {
        final at = src.indexOf('final String subject;', from);
        if (at == -1) break;
        final doc = _normalizeDoc(_precedingDocLines(src, at));
        expect(doc, contains('GLOBAL'));
        expect(doc, contains('GID-13'));
        expect(
          doc,
          contains('tenant axis'),
          reason: '`sub` must not be documented as tenant-scoped',
        );
        checked++;
        from = at + 1;
      }
      expect(checked, 2);
    });

    test('there is NO unified claims type and no shared `tnt` accessor', () {
      final src = File(_sourcePath).readAsStringSync();
      expect(
        RegExp(r'\bclass\s+AoidClaims\b').hasMatch(src),
        isFalse,
        reason:
            'a unified AoidClaims type is the meeting point where the two tnt '
            'values could be confused again. There must be no such type.',
      );
      final code = src
          .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
          .replaceAll(RegExp(r'//[^\n]*'), '');
      expect(
        RegExp(r'\bget\s+tnt\b').hasMatch(code),
        isFalse,
        reason: 'no shared, untyped `tnt` accessor',
      );
    });
  });

  group('the decoders never imply verification', () {
    test('a token with a meaningless signature still decodes — which is why '
        'the method is named decodeUnverified', () {
      // The fixture signature is base64url of 'unverifiable-by-design'. It
      // decodes fine, because nothing checks it. If a future change made these
      // decoders verify, this test would still pass — the doc-comment doctrine
      // gate in tenant_ref/claims source is what pins the naming.
      final claims = AoidAccessClaims.decodeUnverified(
        fx.accessTokenSwitchedToTenantB,
      );
      expect(claims.activeTenant.slug, fx.tenantBSlug);
    });
  });
}
