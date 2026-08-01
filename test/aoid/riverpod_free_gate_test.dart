// The enforceable riverpod firewall for `package:eden_platform_flutter/aoid.dart`.
//
// This is a GATE, not hygiene. AODex resolves flutter_riverpod 3.x while this
// package pins ^2.6.1. In riverpod 3.x `StateNotifier` moved to
// flutter_riverpod/legacy.dart, and eden's AuthNotifier is built on it — so the
// instant anything in aoid.dart's transitive closure names riverpod, AODex
// stops compiling and AOID objective 50's last wave becomes impossible.
//
// Why a closure WALK and not just a grep of lib/src/aoid/:
//   TRD 50-01's test list asks for "no file under lib/src/aoid/ contains
//   package:flutter_riverpod". That check has a hole big enough to drive the
//   whole objective through: a file under lib/src/aoid/ can write
//       import '../auth/auth_provider.dart';
//   and pull riverpod into the closure without the string "flutter_riverpod"
//   ever appearing in lib/src/aoid/. The literal-grep gate passes; AODex still
//   breaks. So the gate below follows relative import/export directives out of
//   lib/aoid.dart transitively and fails on riverpod anywhere it can reach.
//   The flat greps are kept too — they localise a failure faster.
//
// Precedent for gate-as-ordinary-test (not custom_lint, which is used nowhere
// in the org): politihub/flutter-navigators canvass_providers_6way_test.dart
// and the APP-06 grep gate cited in lib/networking.dart:29-31.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _forbiddenPackage = 'package:flutter_riverpod';
const _forbiddenSymbol = 'StateNotifier';

/// Matches a leading `import`/`export` directive and captures its URI.
/// Anchored at line start so a directive mentioned inside a `//` comment
/// (this file's own header, for instance) is never treated as real.
final _directiveRe = RegExp(
  '''^\\s*(?:import|export)\\s+[\\'"]([^\\'"]+)[\\'"]''',
  multiLine: true,
);

/// Strips `//` line comments and `/* */` block comments so that prose
/// mentioning a banned symbol is not mistaken for code using it.
String stripComments(String src) => src
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

/// The result of walking a barrel's transitive, first-party closure.
class ClosureScan {
  ClosureScan(this.visited, this.violations);

  /// Every first-party file reachable from the root, as given paths.
  final Set<String> visited;

  /// Human-readable violations, each naming the offending file.
  final List<String> violations;
}

/// Follows relative (and `package:eden_platform_flutter/`) import/export
/// directives out of [rootPath], collecting every first-party file reachable
/// and every riverpod reference found along the way.
///
/// [libDir] is where `package:eden_platform_flutter/...` URIs resolve to.
ClosureScan scanClosure(String rootPath, {String libDir = 'lib'}) {
  final visited = <String>{};
  final violations = <String>[];
  final queue = <String>[rootPath];

  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    final normalised = File(current).absolute.path;
    if (!visited.add(normalised)) continue;

    final file = File(current);
    if (!file.existsSync()) {
      violations.add('$current -> file does not exist (dangling directive)');
      continue;
    }
    final src = file.readAsStringSync();

    if (stripComments(src).contains(_forbiddenSymbol)) {
      violations.add('$current -> names $_forbiddenSymbol in code');
    }

    for (final m in _directiveRe.allMatches(src)) {
      final uri = m.group(1)!;

      if (uri.startsWith(_forbiddenPackage)) {
        violations.add('$current -> imports $uri');
        continue;
      }
      if (uri.startsWith('dart:')) continue;
      if (uri.startsWith('package:eden_platform_flutter/')) {
        queue.add(
          '$libDir/${uri.substring('package:eden_platform_flutter/'.length)}',
        );
        continue;
      }
      if (uri.startsWith('package:')) continue; // third-party, not walked
      // Relative — resolve against the importing file's directory.
      queue.add(File(current).parent.uri.resolve(uri).toFilePath());
    }
  }

  return ClosureScan(visited, violations);
}

List<File> _dartFilesUnder(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  return d
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
}

List<String> _exportLinesOf(String path) => File(
  path,
).readAsLinesSync().where((l) => l.trimLeft().startsWith('export ')).toList();

const _partBarrels = <String>[
  'storage',
  'claims',
  'native',
  'modes',
  'widgets',
  'redirect',
  'tenant',
];

void main() {
  group('aoid.dart riverpod firewall', () {
    // Item 5 (POSITIVE CONTROL) runs first, and deliberately so. Items 1-2
    // are "assert nothing matches" tests, which pass vacuously if the
    // predicate is broken or the glob is empty. This proves the predicate
    // actually catches a violation before any absence is trusted.
    test('POSITIVE CONTROL: the closure walker detects riverpod reached '
        'INDIRECTLY, through a file that never names it', () {
      final tmp = Directory.systemTemp.createTempSync('aoid_gate_probe');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final libDir = Directory('${tmp.path}/lib')..createSync();
      Directory('${libDir.path}/src/aoid').createSync(recursive: true);
      Directory('${libDir.path}/src/auth').createSync(recursive: true);

      // The barrel and the file under src/aoid/ are both CLEAN by the flat
      // grep: neither contains the string "flutter_riverpod".
      File(
        '${libDir.path}/aoid.dart',
      ).writeAsStringSync("export 'src/aoid/innocent.dart';\n");
      File(
        '${libDir.path}/src/aoid/innocent.dart',
      ).writeAsStringSync("import '../auth/tainted.dart';\n");
      // Riverpod enters two hops away, outside lib/src/aoid/ entirely.
      File('${libDir.path}/src/auth/tainted.dart').writeAsStringSync(
        "import 'package:flutter_riverpod/flutter_riverpod.dart';\n",
      );

      // The flat grep the TRD specified sees nothing wrong...
      final flat = _dartFilesUnder(
        '${libDir.path}/src/aoid',
      ).where((f) => f.readAsStringSync().contains(_forbiddenPackage)).toList();
      expect(
        flat,
        isEmpty,
        reason: 'precondition: the flat grep is blind to this case',
      );

      // ...but the closure walker catches it. This is the gate's real teeth.
      final scan = scanClosure('${libDir.path}/aoid.dart', libDir: libDir.path);
      expect(
        scan.violations,
        isNotEmpty,
        reason:
            'the closure walker MUST detect indirectly-reached riverpod; '
            'if this is empty the gate is decorative',
      );
      expect(scan.violations.join('\n'), contains('tainted.dart'));
    });

    test('POSITIVE CONTROL: a direct riverpod import is detected', () {
      final tmp = Directory.systemTemp.createTempSync('aoid_gate_probe2');
      addTearDown(() => tmp.deleteSync(recursive: true));
      File('${tmp.path}/root.dart').writeAsStringSync(
        "import 'package:flutter_riverpod/flutter_riverpod.dart';\n",
      );

      final scan = scanClosure('${tmp.path}/root.dart', libDir: tmp.path);
      expect(scan.violations, isNotEmpty);
    });

    test('POSITIVE CONTROL: a bare StateNotifier reference is detected, '
        'but the same word inside a comment is not', () {
      final tmp = Directory.systemTemp.createTempSync('aoid_gate_probe3');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final code = File('${tmp.path}/code.dart')
        ..writeAsStringSync('class Foo extends StateNotifier<int> {}\n');
      expect(scanClosure(code.path, libDir: tmp.path).violations, isNotEmpty);

      final comment = File('${tmp.path}/comment.dart')
        ..writeAsStringSync('// mentions StateNotifier in prose only\n');
      expect(scanClosure(comment.path, libDir: tmp.path).violations, isEmpty);
    });

    // Item 1
    test('no file under lib/src/aoid/ imports $_forbiddenPackage', () {
      final files = _dartFilesUnder('lib/src/aoid');
      expect(
        files,
        isNotEmpty,
        reason:
            'lib/src/aoid/ must exist and hold Dart files — an empty '
            'glob would make this assertion vacuous',
      );

      final offenders = files
          .where((f) => f.readAsStringSync().contains(_forbiddenPackage))
          .map((f) => f.path)
          .toList();
      expect(
        offenders,
        isEmpty,
        reason: 'these files import $_forbiddenPackage: $offenders',
      );
    });

    // Item 2
    test('no file under lib/src/aoid/ names $_forbiddenSymbol in code', () {
      final files = _dartFilesUnder('lib/src/aoid');
      expect(files, isNotEmpty);

      final offenders = files
          .where(
            (f) =>
                stripComments(f.readAsStringSync()).contains(_forbiddenSymbol),
          )
          .map((f) => f.path)
          .toList();
      expect(
        offenders,
        isEmpty,
        reason: 'these files name $_forbiddenSymbol: $offenders',
      );
    });

    // The real invariant: the whole closure, not just one directory.
    test('the transitive closure of lib/aoid.dart never reaches riverpod', () {
      final scan = scanClosure('lib/aoid.dart');
      expect(
        scan.violations,
        isEmpty,
        reason:
            'aoid.dart closure violations:\n'
            '${scan.violations.join('\n')}',
      );
      // Guard against a walker that silently visits nothing.
      expect(
        scan.visited.length,
        greaterThanOrEqualTo(8),
        reason:
            'expected aoid.dart + 3 core files + 7 part-barrels to be '
            'walked; only ${scan.visited.length} were',
      );
    });

    // Item 3
    test('lib/aoid.dart exists and every export points inside src/aoid/', () {
      expect(File('lib/aoid.dart').existsSync(), isTrue);

      final exports = _exportLinesOf('lib/aoid.dart');
      expect(exports, isNotEmpty);

      final widened = exports
          .where((l) => !l.startsWith("export 'src/aoid/"))
          .toList();
      expect(
        widened,
        isEmpty,
        reason:
            'aoid.dart may only export from src/aoid/. Offending '
            'lines: $widened',
      );
    });

    // Item 3b
    test('all seven part-barrels exist and are exported by lib/aoid.dart', () {
      final exports = _exportLinesOf('lib/aoid.dart').join('\n');
      for (final name in _partBarrels) {
        expect(
          File('lib/src/aoid/parts/$name.dart').existsSync(),
          isTrue,
          reason:
              'missing part-barrel lib/src/aoid/parts/$name.dart — a '
              'downstream TRD has nowhere to write',
        );
        expect(
          exports,
          contains("export 'src/aoid/parts/$name.dart';"),
          reason: 'lib/aoid.dart does not export part-barrel $name',
        );
      }
    });

    // Item 4
    test('lib/aoid.dart records WHY the firewall exists', () {
      final header = File('lib/aoid.dart').readAsStringSync().toLowerCase();
      expect(
        header,
        contains('flutter_riverpod 3'),
        reason:
            'the header must name the riverpod 3 incompatibility so a '
            'later reader does not delete the barrel as redundant',
      );
      expect(
        header,
        contains('aodex'),
        reason: 'the header must name the consumer that depends on this',
      );
    });

    // Layering: the riverpod side may depend on the core, never the reverse.
    // Checks DIRECTIVES, not raw substrings — the core files legitimately
    // mention aoid_riverpod in their header prose to explain the split, and a
    // naive `contains` flags that as a violation.
    test('nothing under lib/src/aoid/ imports the riverpod side', () {
      final files = _dartFilesUnder('lib/src/aoid');
      expect(files, isNotEmpty);

      final offenders = <String>[];
      for (final f in files) {
        for (final m in _directiveRe.allMatches(f.readAsStringSync())) {
          if (m.group(1)!.contains('aoid_riverpod')) {
            offenders.add('${f.path} -> ${m.group(1)}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'core must not depend on the adapter layer: $offenders',
      );
    });
  });
}
