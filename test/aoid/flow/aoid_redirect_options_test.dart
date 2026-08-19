// the spec test-list items 1-4 — the per-consumer configuration for the
// browser hop.
//
// The four things asserted here are each a one-line setting with a total
// failure blast radius, and each is invisible until it happens to a user.
//
// Item 2 is asserted TWICE, in two files, on purpose:
//   * here, on the FlutterWebAuth2Options object the type produces, and
//   * in aoid_redirect_flow_test.dart, on the instance that actually REACHED
//     the authorize call.
// A field that is set but never threaded through is the common failure and
// the first assertion alone would miss it.

import 'dart:io';

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart'
    show FlutterWebAuth2Options;

/// Every Dart file under `lib/`, with a guard against a silently-empty glob
/// (which would make item 4 vacuous rather than passing).
List<File> _libDartFiles() {
  final dir = Directory('lib');
  expect(
    dir.existsSync(),
    isTrue,
    reason: 'this gate must run from the package root so lib/ is visible',
  );
  final files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
  expect(
    files.length,
    greaterThan(20),
    reason:
        'expected to scan the whole package; found only ${files.length} dart '
        'files under lib/ — the glob is broken, not the code clean',
  );
  return files;
}

/// The single predicate item 4 and its positive control both use.
List<String> _scanForHardcodedBundleId(String path, String source) {
  final hits = <String>[];
  final lines = source.split('\n');
  for (var i = 0; i < lines.length; i++) {
    // Assembled at runtime so this GATE does not itself become the grep hit
    // that `grep -rc "com.justindonnaruma" lib/` is looking for.
    if (lines[i].contains(['com', 'justindonnaruma'].join('.'))) {
      hits.add('$path:${i + 1} — ${lines[i].trim()}');
    }
  }
  return hits;
}

void main() {
  group('item 1: an unset callback scheme fails fast', () {
    test('an empty callbackScheme throws, naming the setting', () {
      expect(
        () => AoidRedirectOptions(callbackScheme: ''),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'callbackScheme'),
        ),
      );
    });

    test('a whitespace-only callbackScheme throws too', () {
      expect(
        () => AoidRedirectOptions(callbackScheme: '   '),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a full URI is rejected — the SCHEME alone is what is wanted', () {
      expect(
        () => AoidRedirectOptions(callbackScheme: 'edenbiz://auth'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('not a valid URL scheme'),
          ),
        ),
      );
    });

    test('the message names the setting and says where to register it', () {
      Object? caught;
      try {
        AoidRedirectOptions(callbackScheme: '');
      } catch (e) {
        caught = e;
      }
      final text = caught.toString();
      expect(text, contains('callbackScheme'));
      expect(text, contains('REQUIRED'));
      expect(text, contains('CFBundleURLSchemes'));
      expect(text, contains('CallbackActivity'));
    });

    test('a valid scheme is accepted and preserved verbatim', () {
      expect(
        AoidRedirectOptions(callbackScheme: 'edenbiz').callbackScheme,
        'edenbiz',
      );
      expect(
        AoidRedirectOptions(callbackScheme: 'aodex').callbackScheme,
        'aodex',
      );
      // Web uses a universal-link-style https target (auth.html).
      expect(
        AoidRedirectOptions(callbackScheme: 'https').callbackScheme,
        'https',
      );
    });
  });

  group('item 2: useWebview is FALSE for the social path', () {
    test('the produced FlutterWebAuth2Options has useWebview: false', () {
      final produced = AoidRedirectOptions(
        callbackScheme: 'edenbiz',
      ).toFlutterWebAuth2Options();

      expect(
        produced.useWebview,
        isFalse,
        reason:
            'flutter_web_auth_2 defaults useWebview to TRUE (options.dart:69) '
            'and a WebView is exactly what Google blocks for social login — '
            'the leg fails with disallowed_useragent',
      );
    });

    test('the PACKAGE default really is true — so this is not a no-op', () {
      // Falsifiability check for the assertion above. If upstream ever flips
      // the default, this test tells us the forcing became redundant rather
      // than letting the previous test pass for the wrong reason.
      expect(
        const FlutterWebAuth2Options().useWebview,
        isTrue,
        reason:
            'flutter_web_auth_2-5.0.3 options.dart:69 — useWebview ?? true. '
            'If this fails the package default changed; re-read options.dart',
      );
    });

    test('useWebview is not consumer-settable — there is no such field', () {
      // A compile-time property, so it is asserted at the source level: no
      // constructor parameter named useWebview exists on AoidRedirectOptions.
      final src = File(
        'lib/src/aoid/flow/aoid_redirect_options.dart',
      ).readAsStringSync();
      expect(src, contains('useWebview: false'));
      expect(
        src,
        isNot(contains('this.useWebview')),
        reason:
            'useWebview must be forced, never accepted from the consumer — '
            'there is no social IdP for which an embedded WebView is right',
      );
      expect(
        src,
        contains('disallowed_useragent'),
        reason: 'the REASON must live next to the setting, or it gets "fixed"',
      );
    });
  });

  group('item 3: preferEphemeral is exposed, not silently inherited', () {
    test('it defaults to false — the cross-app-SSO choice', () {
      expect(
        AoidRedirectOptions(callbackScheme: 'edenbiz').preferEphemeral,
        isFalse,
      );
    });

    test('true and false both reach the produced options object', () {
      expect(
        AoidRedirectOptions(
          callbackScheme: 'edenbiz',
          preferEphemeral: true,
        ).toFlutterWebAuth2Options().preferEphemeral,
        isTrue,
      );
      expect(
        AoidRedirectOptions(
          callbackScheme: 'edenbiz',
          preferEphemeral: false,
        ).toFlutterWebAuth2Options().preferEphemeral,
        isFalse,
      );
    });

    test('both consequences are documented at the declaration', () {
      final src = File(
        'lib/src/aoid/flow/aoid_redirect_options.dart',
      ).readAsStringSync();
      expect(
        src,
        contains('cross-app SSO'),
        reason: 'the reason to leave it false',
      );
      expect(
        src,
        contains('Wants to Use'),
        reason: 'the iOS consent alert — the reason a consumer may want true',
      );
      expect(
        src,
        contains('Android Custom Tabs'),
        reason:
            'it is NOT a cross-platform privacy guarantee; Android shares the '
            'Chrome jar regardless',
      );
    });
  });

  group('item 4: no hardcoded personal bundle identifier under lib/', () {
    test('the string appears nowhere in the package', () {
      final hits = <String>[];
      for (final f in _libDartFiles()) {
        hits.addAll(_scanForHardcodedBundleId(f.path, f.readAsStringSync()));
      }
      expect(
        hits,
        isEmpty,
        reason:
            'a shared library must not ship a per-app bundle identifier. '
            'social_auth_service.dart:37 shipped a personal one to 18 '
            'packages; the spec removed it and the spec must not reintroduce '
            'the shape. Use AoidRedirectOptions.callbackScheme.\n'
            '${hits.join('\n')}',
      );
    });

    test('positive control: the same predicate DOES detect a planted one', () {
      // Without this, the test above passes whenever the glob or the
      // predicate is silently broken.
      const planted = "const scheme = 'com.justindonnaruma.app';";
      expect(
        _scanForHardcodedBundleId('planted_fixture.dart', planted),
        isNotEmpty,
        reason: 'the predicate is broken — it saw nothing in a planted hit',
      );
    });
  });
}
