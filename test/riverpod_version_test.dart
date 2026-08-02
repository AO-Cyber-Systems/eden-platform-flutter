// Stage A of AOID objective 50's riverpod alignment (50-CONTEXT.md D2, TRD 50-06).
//
// This suite pins the VERSION axis and nothing else. It exists so that a silent
// downgrade back to flutter_riverpod 2.x is a red test rather than a surprise in
// a consumer three repos away.
//
// Two independent proofs, deliberately:
//
//   1. COMPILE-TIME — this file imports `package:flutter_riverpod/legacy.dart`.
//      That library does not exist in flutter_riverpod 2.6.1 (verified: its
//      `lib/` contains only `flutter_riverpod.dart` + `src/`). On 2.x this file
//      fails to resolve its import, so the proof cannot be faked by a stale
//      lockfile.
//
//   2. RUNTIME — `pubspec.lock` is parsed and the RESOLVED major asserted. A
//      declared constraint is not a resolved version (AODex declares ^3.0.0 and
//      resolves 3.2.1), so the constraint alone is not evidence.
//
// See doc/riverpod-3-migration.md for the four-stage plan.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
// This import is what makes proof (1) above work. It is NOT a temporary shim —
// this file's whole job is to assert the 3.x layout, so it stays after
// 50-20..50-23 remove the shims from lib/.
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Extract the RESOLVED version of [package] from the text of a `pubspec.lock`.
///
/// Returns `null` when the package is absent. Throws [FormatException] when the
/// package is present but carries no `version:` key, because a package entry
/// without a version means the lockfile is malformed and silently returning
/// `null` there would let the caller's assertion pass vacuously.
String? resolvedLockVersion(String lockYaml, String package) {
  final lines = const LineSplitter().convert(lockYaml);
  // Package entries in pubspec.lock sit at exactly two spaces of indent under
  // the top-level `packages:` key.
  final header = RegExp('^  ${RegExp.escape(package)}:\\s*\$');
  final nextPackage = RegExp(r'^  \S');
  final version = RegExp('^    version:\\s*["\']?([^"\'\\s]+)["\']?\\s*\$');

  final i = lines.indexWhere(header.hasMatch);
  if (i < 0) return null;

  for (var j = i + 1; j < lines.length; j++) {
    final m = version.firstMatch(lines[j]);
    if (m != null) return m.group(1);
    // Reached the next package entry without finding a version.
    if (nextPackage.hasMatch(lines[j])) break;
  }
  throw FormatException('pubspec.lock entry for "$package" has no version key');
}

/// Major component of a semver string, e.g. `'3.3.1'` -> `3`.
int majorOf(String version) {
  final head = version.split('.').first;
  final n = int.tryParse(head);
  if (n == null) throw FormatException('not a semver version: "$version"');
  return n;
}

const _lock2x = '''
packages:
  flutter:
    dependency: "direct main"
    source: sdk
    version: "0.0.0"
  flutter_riverpod:
    dependency: "direct main"
    description:
      name: flutter_riverpod
      sha256: "9532ee6db4a943a1ed8383072a2e3eeda041db5657cdf6d2acecf3c21ecbe7e1"
      url: "https://pub.dev"
    source: hosted
    version: "2.6.1"
  http:
    dependency: "direct main"
    version: "1.2.0"
''';

const _lock3x = '''
packages:
  flutter_riverpod:
    dependency: "direct main"
    description:
      name: flutter_riverpod
      url: "https://pub.dev"
    source: hosted
    version: "3.3.1"
''';

const _lockNoVersion = '''
packages:
  flutter_riverpod:
    dependency: "direct main"
    source: hosted
  http:
    dependency: "direct main"
    version: "1.2.0"
''';

void main() {
  // ---------------------------------------------------------------------
  // The parser is proven DISCRIMINATING before it is pointed at the real
  // lockfile. A parser that returned null for everything would make the real
  // assertion below pass vacuously; these cases rule that out.
  // ---------------------------------------------------------------------
  group('resolvedLockVersion', () {
    test('reads the resolved version out of a riverpod-2 lockfile', () {
      expect(resolvedLockVersion(_lock2x, 'flutter_riverpod'), '2.6.1');
    });

    test('reads the resolved version out of a riverpod-3 lockfile', () {
      expect(resolvedLockVersion(_lock3x, 'flutter_riverpod'), '3.3.1');
    });

    test('does not bleed a neighbouring package version into the answer', () {
      // `flutter` precedes flutter_riverpod in _lock2x and `http` follows it.
      // A parser scanning for the first `version:` anywhere would answer
      // "0.0.0" or "1.2.0"; this pins that it does not.
      expect(resolvedLockVersion(_lock2x, 'flutter'), '0.0.0');
      expect(resolvedLockVersion(_lock2x, 'http'), '1.2.0');
    });

    test('returns null for a package absent from the lockfile', () {
      expect(resolvedLockVersion(_lock2x, 'not_a_real_package'), isNull);
    });

    test('throws rather than returning null when the entry has no version', () {
      expect(
        () => resolvedLockVersion(_lockNoVersion, 'flutter_riverpod'),
        throwsFormatException,
      );
    });

    test('majorOf rejects a non-semver string instead of defaulting', () {
      expect(majorOf('3.3.1'), 3);
      expect(majorOf('2.6.1'), 2);
      expect(() => majorOf('any'), throwsFormatException);
    });
  });

  group('the package resolves flutter_riverpod 3.x', () {
    test('pubspec.yaml declares a ^3 constraint', () {
      final pubspec = File('pubspec.yaml');
      expect(pubspec.existsSync(), isTrue,
          reason: 'flutter test runs from the package root');
      final line = const LineSplitter()
          .convert(pubspec.readAsStringSync())
          .firstWhere((l) => l.startsWith('  flutter_riverpod:'),
              orElse: () => '');
      expect(line, contains('^3.'),
          reason: 'the declared constraint must be a 3.x major');
    });

    test('pubspec.lock RESOLVES a 3.x major', () {
      final lock = File('pubspec.lock');
      expect(lock.existsSync(), isTrue,
          reason: 'run `flutter pub get` before the suite');

      final resolved =
          resolvedLockVersion(lock.readAsStringSync(), 'flutter_riverpod');
      expect(resolved, isNotNull,
          reason: 'flutter_riverpod must appear in pubspec.lock');
      expect(majorOf(resolved!), 3,
          reason: 'resolved flutter_riverpod is $resolved — a silent downgrade '
              'to 2.x breaks AODex, which resolves 3.x');
    });

    test('the transitive riverpod core also resolves 3.x', () {
      final resolved = resolvedLockVersion(
          File('pubspec.lock').readAsStringSync(), 'riverpod');
      expect(resolved, isNotNull);
      expect(majorOf(resolved!), 3);
    });
  });

  group('legacy.dart still ships the symbols Stage A depends on', () {
    // If any of these stopped resolving, the `legacy.dart` shim strategy that
    // makes the version bump separable from the API migration would be dead,
    // and 50-20..50-23 would have to be merged back into this TRD.
    test('StateController still holds and mutates state', () {
      final controller = StateController<int>(1);
      addTearDown(controller.dispose);
      expect(controller.state, 1);
      controller.state = 2;
      expect(controller.state, 2);
    });

    test('StateNotifierProvider still drives a StateNotifier', () {
      final provider = StateNotifierProvider<_CounterNotifier, int>(
          (ref) => _CounterNotifier());
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(provider), 0);
      container.read(provider.notifier).increment();
      expect(container.read(provider), 1);
    });

    test('StateProvider still resolves and reads', () {
      final counter = StateProvider<int>((ref) => 7);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(counter), 7);
    });

    test('ChangeNotifierProvider still resolves and notifies', () {
      final provider = ChangeNotifierProvider<_Chatty>((ref) => _Chatty());
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final chatty = container.read(provider);
      var notified = 0;
      chatty.addListener(() => notified++);
      chatty.bump();
      expect(notified, 1);
    });
  });
}

class _CounterNotifier extends StateNotifier<int> {
  _CounterNotifier() : super(0);
  void increment() => state = state + 1;
}

class _Chatty extends ChangeNotifier {
  void bump() => notifyListeners();
}
