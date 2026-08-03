// THE OBJECTIVE'S REQUIRED MULTI-TENANT ISOLATION GATE (wrong_tenant_assertion).
//
// TRD 50-03 test-list items 9-11, plus four extra regions that close holes the
// three named items leave open.
//
// A running test cannot observe "this does not compile", so this drives the
// ANALYZER: it copies `fixtures/conflation_probe.dart.txt` into a dot-directory
// inside the package (skipped by `flutter analyze`'s default sweep, but still
// covered by `.dart_tool/package_config.json`, so
// `package:eden_platform_flutter/eden_platform.dart` resolves), runs
// `dart analyze --format=json` over it, and asserts on the diagnostics.
//
// TWO RULES, both learned the hard way:
//
//   1. Assert on LOCATION + DIAGNOSTIC CODE, never on a total count. A probe
//      that fails to resolve emits errors on every line and would satisfy any
//      count-based check while proving nothing at all.
//
//   2. The positive control shares the file with the negative regions. If the
//      correctly-typed assignments are ALSO dirty, the fixture is broken and
//      the negative regions are meaningless — so a dirty positive control is a
//      hard failure, not a pass.
//
// There is NO skip path. `markTestSkipped` on the objective's required
// isolation assertion is a false green; if the analyzer cannot be run, this
// fails loudly instead.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _probeSource = 'test/aoid/claims/fixtures/conflation_probe.dart.txt';

/// Dot-directory: the analyzer's default sweep skips paths with a leading-dot
/// segment, so `flutter analyze` stays clean while `dart analyze <path>` still
/// analyses it on demand.
const _probeDir = '.aoid_conflation_probe';
const _probeFile = '$_probeDir/probe.dart';

const _beginMarker = '// >>> REGION: ';
const _endMarker = '// <<< END REGION';

/// A contiguous, named span of probe lines. Lines are 1-based, matching the
/// analyzer's own numbering.
class _Region {
  const _Region(this.name, this.firstLine, this.lastLine);
  final String name;
  final int firstLine;
  final int lastLine;
  bool contains(int line) => line >= firstLine && line <= lastLine;
  @override
  String toString() => '$name (lines $firstLine-$lastLine)';
}

/// One analyzer diagnostic, flattened to what the assertions need.
class _Diagnostic {
  const _Diagnostic(this.code, this.severity, this.line, this.message);
  final String code;
  final String severity;
  final int line;
  final String message;
  @override
  String toString() => '$severity $code @line $line: $message';
}

Map<String, _Region> _parseRegions(List<String> lines) {
  final regions = <String, _Region>{};
  String? open;
  var openAt = 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.startsWith(_beginMarker)) {
      open = line.substring(_beginMarker.length).trim();
      openAt = i + 1;
    } else if (line.trimRight() == _endMarker && open != null) {
      regions[open] = _Region(open, openAt, i + 1);
      open = null;
    }
  }
  expect(open, isNull, reason: 'unterminated region `$open` in $_probeSource');
  return regions;
}

/// Locates a `dart` binary. `flutter test` runs on the Dart VM shipped with the
/// Flutter SDK, so the sibling of [Platform.resolvedExecutable] is the reliable
/// first candidate; PATH is the fallback.
String _dartExecutable() {
  final sep = Platform.pathSeparator;
  final exe = Platform.resolvedExecutable;
  final dir = exe.substring(0, exe.lastIndexOf(sep));
  final candidates = <String>[
    if (exe.split(sep).last.startsWith('dart')) exe,
    '$dir${sep}dart',
    'dart',
  ];
  for (final c in candidates) {
    try {
      final r = Process.runSync(c, ['--version']);
      if (r.exitCode == 0) return c;
    } on ProcessException {
      continue;
    }
  }
  fail(
    'no `dart` executable found (tried: ${candidates.join(", ")}). This gate '
    'is the objective 50 REQUIRED multi-tenant isolation assertion — it must '
    'not be skipped. Fix the environment or the gate is a false green.',
  );
}

/// Parses `dart analyze --format=json` output defensively: the diagnostics
/// array has been spelled both `diagnostics` and `errors` across SDK versions,
/// so it is located by key search rather than pinned to one schema.
List<_Diagnostic> _parseDiagnostics(String stdout) {
  final start = stdout.indexOf('{');
  expect(
    start,
    isNonNegative,
    reason: 'dart analyze produced no JSON object. Raw output:\n$stdout',
  );
  final decoded = jsonDecode(stdout.substring(start));
  expect(decoded, isA<Map<String, dynamic>>());
  final map = decoded as Map<String, dynamic>;

  List<dynamic>? array;
  for (final key in const ['diagnostics', 'errors']) {
    final v = map[key];
    if (v is List) {
      array = v;
      break;
    }
  }
  expect(
    array,
    isNotNull,
    reason:
        'no diagnostics array in dart analyze JSON. Keys were: '
        '${map.keys.toList()}',
  );

  return array!.map((raw) {
    final d = raw as Map<String, dynamic>;
    final loc = d['location'] as Map<String, dynamic>?;
    final range = loc?['range'] as Map<String, dynamic>?;
    final startPos = range?['start'] as Map<String, dynamic>?;
    final line = (startPos?['line'] ?? loc?['startLine'] ?? -1) as int;
    return _Diagnostic(
      (d['code'] ?? '<no code>').toString(),
      (d['severity'] ?? '<no severity>').toString(),
      line,
      (d['problemMessage'] ?? d['message'] ?? '').toString(),
    );
  }).toList();
}

void main() {
  late Map<String, _Region> regions;
  late List<_Diagnostic> diagnostics;
  late List<String> probeLines;

  setUpAll(() {
    final source = File(_probeSource);
    expect(
      source.existsSync(),
      isTrue,
      reason:
          '$_probeSource is missing. Without the probe this gate cannot run, '
          'and the objective\'s required tenant-isolation assertion is not '
          'being made.',
    );
    final text = source.readAsStringSync();
    probeLines = text.split('\n');
    regions = _parseRegions(probeLines);

    final dir = Directory(_probeDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync();
    // Copy VERBATIM so analyzer line numbers match the source's line numbers.
    File(_probeFile).writeAsStringSync(text);

    final result = Process.runSync(_dartExecutable(), [
      'analyze',
      '--format=json',
      _probeDir,
    ], workingDirectory: Directory.current.path);

    // `dart analyze` exits NON-ZERO when it finds errors, which is the
    // EXPECTED outcome here. The exit code is deliberately not asserted on;
    // the JSON is what matters.
    diagnostics = _parseDiagnostics(result.stdout.toString());

    dir.deleteSync(recursive: true);
  });

  List<_Diagnostic> inRegion(String name) {
    final region = regions[name];
    expect(region, isNotNull, reason: 'no region `$name` in $_probeSource');
    return diagnostics.where((d) => region!.contains(d.line)).toList();
  }

  List<_Diagnostic> errorsIn(String name) =>
      inRegion(name).where((d) => d.severity == 'ERROR').toList();

  group('probe integrity — without these the gate proves nothing', () {
    test('the probe RESOLVED: no unresolved-import or undefined-name '
        'diagnostics anywhere', () {
      final resolutionFailures = diagnostics
          .where(
            (d) => const {
              'uri_does_not_exist',
              'uri_has_not_been_generated',
              'undefined_class',
              'undefined_identifier',
              'undefined_function',
              'not_a_type',
            }.contains(d.code),
          )
          .toList();
      expect(
        resolutionFailures,
        isEmpty,
        reason:
            'the probe could not see '
            'package:eden_platform_flutter/eden_platform.dart. '
            'Every reference would then be an error, and the "MUST NOT '
            'COMPILE" regions below would pass for entirely the wrong reason.\n'
            '${resolutionFailures.join('\n')}',
      );
    });

    test('every expected region was found in the probe', () {
      expect(
        regions.keys.toSet(),
        containsAll(<String>[
          'positiveControl',
          'conflateAccessFromHome',
          'conflateHomeFromActive',
          'noValueGetter',
          'rawStringIsNotATenantRef',
          'noLeakToPlainString',
          'noVarianceHole',
          'toStringCannotBeOverridden',
        ]),
      );
    });

    // Item 11 — THE CONTROL. Without it, items 9 and 10 pass whenever the
    // analyzer errors for any unrelated reason.
    test('POSITIVE CONTROL: the correctly-typed assignments compile clean — '
        'zero errors AND zero warnings', () {
      final bad = inRegion(
        'positiveControl',
      ).where((d) => d.severity == 'ERROR' || d.severity == 'WARNING').toList();
      expect(
        bad,
        isEmpty,
        reason:
            'the CORRECT assignments do not compile. Either the claim types '
            'changed shape (e.g. a field widened to String) or the probe is '
            'broken — either way the negative regions below prove nothing.\n'
            '${bad.join('\n')}',
      );
    });
  });

  group('conflating the two tnt values is a COMPILE error', () {
    // Item 9
    test('assigning a HOME tenant UUID where an ACTIVE tenant SLUG is '
        'expected is rejected by the analyzer', () {
      final errors = errorsIn('conflateAccessFromHome');
      expect(
        errors.map((d) => d.code),
        contains('invalid_assignment'),
        reason:
            'AoidHomeTenantId became assignable to AoidActiveTenantSlug. The '
            'two tnt claims can now be conflated silently — sending the home '
            'UUID as `active_tenant` would become a runtime invalid_grant '
            'instead of a compile error. Check for a new `implements` clause, '
            'a shared supertype, or a typedef standing in for the extension '
            'type.\nDiagnostics in region: $errors',
      );
    });

    // Item 10
    test('assigning an ACTIVE tenant SLUG where a HOME tenant UUID is '
        'expected is rejected by the analyzer', () {
      final errors = errorsIn('conflateHomeFromActive');
      expect(
        errors.map((d) => d.code),
        contains('invalid_assignment'),
        reason:
            'AoidActiveTenantSlug became assignable to AoidHomeTenantId. '
            'Local user linking keyed on this would re-link the account on '
            'every tenant switch.\nDiagnostics in region: $errors',
      );
    });
  });

  group('the holes a determined refactor would open are closed too', () {
    test('neither type exposes a semantically neutral `value` accessor', () {
      final errors = errorsIn('noValueGetter');
      expect(
        errors.map((d) => d.code),
        contains('undefined_getter'),
        reason:
            'a `value` getter was added. `AoidActiveTenantSlug(homeId.uuid)` '
            'is self-evidently wrong at the call site; '
            '`AoidActiveTenantSlug(homeId.value)` is not.\n$errors',
      );
      expect(
        errors.where((d) => d.code == 'undefined_getter').length,
        greaterThanOrEqualTo(2),
        reason: 'both types must reject `.value`, not just one',
      );
    });

    test('a raw String cannot become either type implicitly', () {
      final errors = errorsIn('rawStringIsNotATenantRef');
      expect(
        errors.map((d) => d.code),
        contains('invalid_assignment'),
        reason:
            'a String became implicitly assignable to a tenant ref, so an '
            'arbitrary string can now arrive where a checked one is '
            'expected.\n$errors',
      );
      expect(
        errors.where((d) => d.code == 'invalid_assignment').length,
        greaterThanOrEqualTo(2),
        reason: 'both directions must be rejected',
      );
    });

    test('neither type erases back to String or Object implicitly', () {
      expect(
        errorsIn('noLeakToPlainString').map((d) => d.code),
        contains('invalid_assignment'),
        reason:
            'a tenant ref can now be passed where a plain String or Object is '
            'expected, losing its meaning silently on the way.',
      );
    });

    test('collections and nullable forms open no variance hole', () {
      final errors = errorsIn('noVarianceHole');
      expect(errors.map((d) => d.code), contains('invalid_assignment'));
      expect(
        errors.where((d) => d.code == 'invalid_assignment').length,
        greaterThanOrEqualTo(2),
        reason: 'both List<A> -> List<B> and A? -> B? must be rejected',
      );
    });

    test('an extension type still cannot declare toString — which is why '
        'debugLabel exists', () {
      expect(
        errorsIn('toStringCannotBeOverridden').map((d) => d.code),
        contains('extension_type_declares_member_of_object'),
        reason:
            'Dart now permits an extension type to override toString(). '
            'tenant_ref.dart works around that restriction with `debugLabel`; '
            'revisit it.',
      );
    });
  });

  group('the probe stays out of the build', () {
    test('the probe is stored as .dart.txt and no probe .dart file is '
        'tracked by git', () {
      expect(File(_probeSource).existsSync(), isTrue);
      final tracked = Process.runSync('git', [
        'ls-files',
        'test/aoid/claims/fixtures/',
      ], workingDirectory: Directory.current.path);
      final files = tracked.stdout.toString().trim().split('\n');
      expect(
        files,
        contains(_probeSource),
        reason:
            'the probe fixture must be committed, or CI cannot run this gate',
      );
      expect(
        files.where(
          (f) => f.contains('conflation_probe') && f.endsWith('.dart'),
        ),
        isEmpty,
        reason:
            'a compiled copy of the probe is tracked. It contains deliberate '
            'compile errors and would make `flutter analyze` red for every '
            'consumer of this package.',
      );
    });

    test('the temp probe directory was cleaned up', () {
      expect(Directory(_probeDir).existsSync(), isFalse);
    });
  });
}
