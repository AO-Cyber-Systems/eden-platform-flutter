// TRD 52-01 test-list items 12-15 — the resolver, its release-stripped test
// seam, and the non-export gate.
//
// Items 14 and 15 are SOURCE gates. Per the suite's established rule (see
// test/aoid/source_utils.dart), each carries a POSITIVE CONTROL: the same
// predicate run on a synthetic source that contains the violation, so a
// predicate that can never fire fails loudly instead of passing vacuously.

import 'dart:io';

import 'package:eden_platform_flutter/src/aoid/passkey/aoid_passkey_authenticator.dart';
import 'package:eden_platform_flutter/src/aoid/passkey/aoid_passkey_resolver.dart';
import 'package:eden_platform_flutter/src/aoid/passkey/aoid_platform_passkey_authenticator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../source_utils.dart';

const String _resolverPath = 'lib/src/aoid/passkey/aoid_passkey_resolver.dart';

/// Every assignment to the override's backing field: `=` or `??=`, not `==`.
final RegExp _overrideAssignment = RegExp(r'_debugOverride\s*(\?\?)?=(?!=)');

/// Item 14's predicate: the offsets of override assignments that sit OUTSIDE
/// an `assert(() { ... }())` body in [src] (already comment-stripped).
///
/// The assert body is found by brace counting from `assert(() {` to its
/// matching `}`, which must be followed by `())` — the immediately-invoked
/// closure form. Anything else (an `if (kDebugMode)`, a plain setter body)
/// leaves the assignment live in release builds and is reported.
List<int> _assignmentsOutsideAssert(String src) {
  final assertBodies = <(int, int)>[];
  for (final open in RegExp(r'assert\(\s*\(\)\s*\{').allMatches(src)) {
    var depth = 1;
    var i = open.end;
    while (i < src.length && depth > 0) {
      if (src[i] == '{') depth++;
      if (src[i] == '}') depth--;
      i++;
    }
    if (depth == 0 && RegExp(r'^\s*\(\s*\)\s*\)').hasMatch(src.substring(i))) {
      assertBodies.add((open.end, i));
    }
  }
  return [
    for (final hit in _overrideAssignment.allMatches(src))
      if (!assertBodies.any((b) => hit.start >= b.$1 && hit.end <= b.$2))
        hit.start,
  ];
}

/// A stand-in authenticator. It never produces an assertion.
class _FakeAuthenticator implements AoidPasskeyAuthenticator {
  @override
  Future<bool> isSupported() async => true;

  @override
  Future<AoidPasskeyAttempt> getAssertion(
    Map<String, dynamic> publicKey,
  ) async => const AoidPasskeyNotAsserted(AoidPasskeyFailure.cancelled);
}

void main() {
  tearDown(() => debugAoidPasskeyAuthenticatorOverride = null);

  test('12. resolves to the platform authenticator by default', () {
    expect(
      resolveAoidPasskeyAuthenticator(),
      isA<AoidPlatformPasskeyAuthenticator>(),
    );
  });

  test('13. the debug override wins while set; null restores the default', () {
    final fake = _FakeAuthenticator();

    debugAoidPasskeyAuthenticatorOverride = fake;
    expect(resolveAoidPasskeyAuthenticator(), same(fake));

    debugAoidPasskeyAuthenticatorOverride = null;
    expect(
      resolveAoidPasskeyAuthenticator(),
      isA<AoidPlatformPasskeyAuthenticator>(),
    );
  });

  group('14. source gate: the override is assignable ONLY inside an assert', () {
    test(
      'the resolver assigns the override only inside assert(() {...}())',
      () {
        final raw = File(_resolverPath).readAsStringSync();
        final src = stripComments(raw);

        // Non-vacuity: the stripper removed the doc comments, and the real
        // assignment is still visible to the predicate.
        expect(
          src.length,
          lessThan(raw.length),
          reason: 'stripper removed nothing',
        );
        expect(
          _overrideAssignment.allMatches(src),
          isNotEmpty,
          reason: 'no assignment found — the gate would pass vacuously',
        );

        expect(
          _assignmentsOutsideAssert(src),
          isEmpty,
          reason:
              'an override assignment outside an assert survives into release '
              'builds, letting a consumer substitute the authenticator',
        );
      },
    );

    test('positive control: the predicate fires on a bare assignment', () {
      const bare = '''
AoidPasskeyAuthenticator? _debugOverride;
set debugAoidPasskeyAuthenticatorOverride(AoidPasskeyAuthenticator? value) {
  _debugOverride = value;
}
''';
      const debugModeOnly = '''
set debugAoidPasskeyAuthenticatorOverride(AoidPasskeyAuthenticator? value) {
  if (kDebugMode) { _debugOverride = value; }
}
''';
      const lazyInit = '''
AoidPasskeyAuthenticator resolve() => _debugOverride ??= const X();
''';
      const insideAssert = '''
set debugAoidPasskeyAuthenticatorOverride(AoidPasskeyAuthenticator? value) {
  assert(() { _debugOverride = value; return true; }());
}
''';
      expect(_assignmentsOutsideAssert(bare), hasLength(1));
      expect(_assignmentsOutsideAssert(debugModeOnly), hasLength(1));
      expect(_assignmentsOutsideAssert(lazyInit), hasLength(1));
      // Negative control: the accepted form is not reported.
      expect(_assignmentsOutsideAssert(insideAssert), isEmpty);
    });
  });

  group('15. surface gate: nothing in lib/src/aoid/passkey/ is exported', () {
    test('no export directive anywhere under lib/ names a passkey file', () {
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      final scanned = files.map((f) => f.path).toSet();

      // Non-vacuity: the public barrel and EVERY part-barrel are in the scan.
      final parts = Directory('lib/src/aoid/parts')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .map((f) => f.path)
          .toList();
      expect(parts, hasLength(greaterThanOrEqualTo(7)), reason: 'parts walk');
      expect(scanned, contains('lib/eden_platform.dart'));
      expect(scanned, containsAll(parts));

      final offenders = <String>[
        for (final f in files)
          for (final line in _passkeyExports(
            stripComments(f.readAsStringSync()),
          ))
            '${f.path}: $line',
      ];
      expect(
        offenders,
        isEmpty,
        reason:
            'exporting a passkey file hands app-owned Dart a way to obtain '
            'or substitute the authenticator (locked decision 1)',
      );
    });

    test('positive control: the predicate fires on a synthetic export', () {
      for (final name in _passkeyFiles) {
        expect(
          _passkeyExports("library;\n\nexport '../passkey/$name';\n"),
          hasLength(1),
          reason: name,
        );
        expect(
          _passkeyExports(
            'export "package:eden_platform_flutter/src/aoid/passkey/$name" '
            'show Foo;',
          ),
          hasLength(1),
          reason: '$name (double quotes, package URI, show clause)',
        );
      }
      // Negative control: an unrelated export and an IMPORT are not reported.
      expect(
        _passkeyExports(
          "export '../flow/aoid_native_flow.dart';\n"
          "import '../passkey/aoid_passkey_resolver.dart';\n",
        ),
        isEmpty,
      );
    });
  });
}

/// The three files TRD 52-01 creates under lib/src/aoid/passkey/.
const List<String> _passkeyFiles = [
  'aoid_platform_passkey_authenticator.dart',
  'aoid_passkey_resolver.dart',
  'aoid_passkey_authenticator.dart',
];

/// Item 15's predicate: every `export` directive in [src] that names one of
/// [_passkeyFiles].
List<String> _passkeyExports(String src) => [
  for (final m in RegExp(
    r'''^\s*export\s+['"]([^'"]+)['"]''',
    multiLine: true,
  ).allMatches(src))
    if (_passkeyFiles.any(
      (name) => m.group(1)!.endsWith('/$name') || m.group(1) == name,
    ))
      m.group(0)!.trim(),
];
