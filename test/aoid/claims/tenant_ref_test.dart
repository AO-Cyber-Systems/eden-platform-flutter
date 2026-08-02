// TRD 50-03 test-list items 1-3 — the shape of the two `tnt` types.
//
// The COMPILE-error property (assigning one where the other is expected) cannot
// be observed from a running test, so it is proven separately by an analyzer run
// in no_conflation_compile_gate_test.dart. This file pins everything that IS
// observable at runtime, plus the structural properties of the declarations that
// a future "tidy-up" would quietly remove.
//
// Why the source-structure assertions below are scoped to a single declaration
// rather than grepping the whole file: a file-wide grep cannot tell WHICH
// declaration it matched. TRD 50-04's `TELEMETRY ONLY` gate survived a mutation
// that moved the comment onto the wrong class. Swapping this file's two doc
// comments would be exactly that defect — and would be an actively harmful
// swap, since the doc comment IS the disambiguation. So every assertion here
// names the declaration it is about.

import 'dart:io';

import 'package:eden_platform_flutter/aoid.dart';
import 'package:flutter_test/flutter_test.dart';

const _sourcePath = 'lib/src/aoid/claims/tenant_ref.dart';

/// The full text of `tenant_ref.dart`.
String _source() => File(_sourcePath).readAsStringSync();

/// Strips `///` and `//` line comments and `/* */` blocks, so an assertion
/// about CODE is never satisfied (or defeated) by prose. Without this, the
/// doc comment "names the TYPE as well as the value" would trip the
/// no-`value`-member check below.
String _codeOnly(String src) => src
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

/// Strips comment markers and collapses whitespace, so a phrase assertion is
/// not defeated (nor a negative assertion satisfied) purely by where the text
/// happened to wrap. TRD 50-04 lost a gate to exactly that.
String _normalizeComment(String raw) => raw
    .split('\n')
    .map((l) {
      final t = l.trimLeft();
      if (t.startsWith('///')) return t.substring(3);
      if (t.startsWith('//')) return t.substring(2);
      return l;
    })
    .join(' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Everything from the start of [name]'s doc comment through the closing brace
/// of its declaration body.
///
/// Used so an assertion about `AoidActiveTenantSlug` cannot be satisfied by text
/// that actually belongs to `AoidHomeTenantId` (or to the file header).
String _declarationBlockOf(String name) {
  final src = _source();
  final declIndex = src.indexOf('extension type const $name(');
  expect(
    declIndex,
    isNonNegative,
    reason:
        'no `extension type const $name(...)` declaration found in '
        '$_sourcePath. If this type was converted to a class or a typedef, '
        'the compile-error property may be gone — see '
        'no_conflation_compile_gate_test.dart.',
  );

  // Walk backwards over the contiguous run of `///` doc-comment lines that
  // immediately precede the declaration. Stops at the first line that is not a
  // doc comment, so the file header (which uses `//`) is never included.
  final before = src.substring(0, declIndex).split('\n');
  var firstDocLine = before.length - 1;
  while (firstDocLine > 0 &&
      before[firstDocLine - 1].trimLeft().startsWith('///')) {
    firstDocLine--;
  }
  final docStart =
      before.sublist(0, firstDocLine).join('\n').length +
      (firstDocLine > 0 ? 1 : 0);

  // Balance braces from the declaration's opening `{` to find the body end.
  final bodyStart = src.indexOf('{', declIndex);
  expect(bodyStart, isNonNegative, reason: '$name has no body');
  var depth = 0;
  var i = bodyStart;
  for (; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) break;
    }
  }
  return src.substring(docStart, i + 1);
}

void main() {
  group('AoidActiveTenantSlug — the ACCESS token tnt (ACTIVE tenant SLUG)', () {
    // Item 1
    test('exposes the slug under a name that says what it is', () {
      const slug = AoidActiveTenantSlug('acme');
      expect(slug.slug, 'acme');
      expect(slug.isEmpty, isFalse);
      expect(const AoidActiveTenantSlug('').isEmpty, isTrue);
    });

    test('debugLabel names the TYPE, so a log line is unambiguous', () {
      const slug = AoidActiveTenantSlug('acme');
      expect(slug.debugLabel, 'AoidActiveTenantSlug(acme)');
      expect(
        slug.debugLabel,
        isNot(contains('HomeTenant')),
        reason: 'the label must not name the other type',
      );
    });
  });

  group('AoidHomeTenantId — the ID token tnt (HOME tenant UUID)', () {
    // Item 2
    test('exposes the uuid under a name that says what it is', () {
      const home = AoidHomeTenantId('018f3a2b-4c5d-4e6f-8a9b-0c1d2e3f4a5b');
      expect(home.uuid, '018f3a2b-4c5d-4e6f-8a9b-0c1d2e3f4a5b');
      expect(home.isEmpty, isFalse);
      expect(const AoidHomeTenantId('').isEmpty, isTrue);
    });

    test('debugLabel names the TYPE, so a log line is unambiguous', () {
      const home = AoidHomeTenantId('018f3a2b-4c5d-4e6f-8a9b-0c1d2e3f4a5b');
      expect(
        home.debugLabel,
        'AoidHomeTenantId(018f3a2b-4c5d-4e6f-8a9b-0c1d2e3f4a5b)',
      );
      expect(
        home.debugLabel,
        isNot(contains('ActiveTenant')),
        reason: 'the label must not name the other type',
      );
    });
  });

  group('the two types are not, and must not become, interchangeable', () {
    // Item 3 — the runtime-observable half. The compile-time half is
    // no_conflation_compile_gate_test.dart's `noValueGetter` region, which
    // proves `.value` is an `undefined_getter` on BOTH types.
    for (final name in ['AoidActiveTenantSlug', 'AoidHomeTenantId']) {
      test('$name declares no member named `value`', () {
        final code = _codeOnly(_declarationBlockOf(name));
        expect(
          RegExp(r'\bvalue\b').hasMatch(code),
          isFalse,
          reason:
              'A `value` accessor on $name is the convenience that '
              'reintroduces the bug. `AoidActiveTenantSlug(homeId.uuid)` is '
              'self-evidently wrong at the call site; '
              '`AoidActiveTenantSlug(homeId.value)` is not. Keep the '
              'representation accessors named `slug` and `uuid`.\n'
              'Declaration code was:\n$code',
        );
      });

      test('$name has no `implements` clause — no common supertype', () {
        final block = _declarationBlockOf(name);
        final header = block.substring(
          block.indexOf('extension type const $name('),
        );
        final headerLine = header.substring(0, header.indexOf('{'));
        expect(
          headerLine,
          isNot(contains('implements')),
          reason:
              'An `implements` clause on $name would give the two types a '
              'shared supertype and restore assignability somewhere. The '
              'ABSENCE of interchangeability is the feature. '
              'Header was: $headerLine',
        );
      });
    }

    test('the doc comment ON AoidActiveTenantSlug describes the ACTIVE tenant '
        'SLUG — and not the home UUID', () {
      final block = _declarationBlockOf('AoidActiveTenantSlug');
      final doc = _normalizeComment(
        block.substring(0, block.indexOf('extension type')),
      );
      expect(doc, contains('ACCESS token'));
      expect(doc, contains('ACTIVE'));
      expect(doc, contains('SLUG'));
      expect(
        doc,
        isNot(contains('UUID of the HOME')),
        reason:
            'the two doc comments have been SWAPPED — this is worse than '
            'having none, because the doc comment IS the disambiguation',
      );
    });

    test('the doc comment ON AoidHomeTenantId describes the HOME tenant UUID — '
        'and not the active slug', () {
      final block = _declarationBlockOf('AoidHomeTenantId');
      final doc = _normalizeComment(
        block.substring(0, block.indexOf('extension type')),
      );
      expect(doc, contains('ID token'));
      expect(doc, contains('HOME'));
      expect(doc, contains('UUID'));
      expect(
        doc,
        isNot(contains('SLUG of the ACTIVE')),
        reason: 'the two doc comments have been SWAPPED',
      );
      expect(
        doc,
        contains('active_tenant'),
        reason:
            'the "never send this as active_tenant" warning belongs on this '
            'type, where the mistake would be made',
      );
    });

    test('the file header carries the DO-NOT-UNIFY instruction', () {
      final header = _source();
      final firstDecl = header.indexOf('///');
      final preamble = _normalizeComment(header.substring(0, firstDecl));
      expect(
        preamble,
        contains('DO NOT'),
        reason:
            'the next reader will want to tidy these into one type; the '
            'header must tell them not to',
      );
      expect(preamble, contains('COMPILE error'));
      expect(
        preamble,
        contains('tokens.go'),
        reason: 'the header must cite the Go source of truth',
      );
      expect(
        preamble,
        contains('service.go'),
        reason:
            'the header must name service.go as the tie-breaker, because the '
            'struct-level comment in tokens.go is stale and says the opposite',
      );
    });
  });

  group('documented limitations (so nobody relies on what is not there)', () {
    // Dart forbids an extension type from declaring a member named `toString`
    // (diagnostic: extension_type_declares_member_of_object). Interpolation
    // therefore yields the ERASED representation. This is pinned so that the
    // `debugLabel` accessor is understood as a deliberate workaround rather
    // than deleted as redundant, and so that a future Dart that DID allow the
    // override would show up here.
    test('string interpolation yields the bare value, NOT a typed label', () {
      const slug = AoidActiveTenantSlug('acme');
      expect(
        '$slug',
        'acme',
        reason:
            'extension types erase to their representation; use debugLabel '
            'in logs',
      );
      const home = AoidHomeTenantId('018f3a2b');
      expect('$home', '018f3a2b');
    });
  });
}
