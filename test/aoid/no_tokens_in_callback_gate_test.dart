// D6 GATE. No eden code may read an access or
// refresh token out of a callback URL, and none may construct a URL
// containing one. Tokens in a URL leak to browser history, Referer headers,
// proxy access logs and — for any Process.run launcher — shell history.
//
// The callback carries an authorization CODE, which is exchanged over POST
// for tokens in a response BODY.
//
// If this test fails, do not relax the pattern. Fix the call site.
//
// SCOPE: all of lib/, recursively — NOT a list of the two files the SSO removal
// happened to touch. The redirect flow adds another callback handler in the next wave
// and must be covered automatically, without anyone remembering to opt in.
//
// WHAT THIS GATE CANNOT DO (read before trusting it):
// A name-based grep cannot catch a token smuggled under a benign parameter
// name — eden-platform-go proved exactly that (its D6-M2/D6-M4
// mutations shipped the token as `?tok=<access>` while a `grep access_token=`
// gate stayed green). That class of defect is covered instead by the
// VALUE-based assertions in test/social_auth_service_test.dart
// ("no token VALUE from the callback URL ever reaches the session"), which
// are mutation-proven. This gate covers the textual//regression half; that
// suite covers the behavioural half. Neither is sufficient alone.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A single forbidden construct found in a source file.
class Violation {
  Violation(this.path, this.line, this.text, this.reason);

  final String path;
  final int line;
  final String text;
  final String reason;

  @override
  String toString() => '$path:$line — $reason\n    ${text.trim()}';
}

/// True for lines that are wholly a Dart comment. Used ONLY to keep the
/// Process.run check from firing on the comments that document its removal —
/// never to soften a token pattern.
bool _isCommentLine(String line) {
  final t = line.trimLeft();
  return t.startsWith('//') || t.startsWith('*') || t.startsWith('/*');
}

/// READ SIDE: a token pulled out of a URL's parameters, under any receiver
/// name (`uri.queryParameters[...]`, `params[...]`, `qp[...]`,...).
final _readPatterns = <RegExp, String>{
  RegExp(
    r"""queryParameters\s*\[\s*['"](access_token|refresh_token)['"]\s*\]""",
  ): 'reads a token out of a URL query string',
  RegExp(r"""\bparams\s*\[\s*['"](access_token|refresh_token)['"]\s*\]"""):
      'reads a token out of a parsed-callback parameter map',
  RegExp(r"""\bfragment\w*\s*\[\s*['"](access_token|refresh_token)['"]\s*\]"""):
      'reads a token out of a URL fragment',
};

/// WRITE SIDE: a URL being CONSTRUCTED with a token in it. This is the half
/// that stops the SDK from starting to produce the pattern the server just removed
/// from the server.
final _writePatterns = <RegExp, String>{
  RegExp(
    r'(access_token|refresh_token)\s*='
    r'(?!=)(?!\s*(decoded|json|body|response|map|payload))',
  ): 'builds a URL (or query string) containing a token',
};

/// The single predicate every test in this file uses — including the positive
/// control, so items 1/2/4 cannot pass merely by globbing nothing.
List<Violation> scanSource(String path, String source) {
  final found = <Violation>[];
  final lines = source.split('\n');

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];

    _readPatterns.forEach((re, reason) {
      if (re.hasMatch(line)) found.add(Violation(path, i + 1, line, reason));
    });

    // The write-side pattern is checked against string/URL context only. A
    // JSON body key (`decoded['access_token']`) is NOT a URL and is the
    // CORRECT way to receive a token — the server's exchange returns exactly that.
    _writePatterns.forEach((re, reason) {
      if (!re.hasMatch(line)) return;
      // `access_token":` inside a documented JSON shape is a body, not a URL.
      if (RegExp(r'''(access_token|refresh_token)\s*"?\s*:''').hasMatch(line)) {
        return;
      }
      found.add(Violation(path, i + 1, line, reason));
    });
  }
  return found;
}

List<File> libDartFiles() {
  final dir = Directory('lib');
  expect(
    dir.existsSync(),
    isTrue,
    reason: 'gate must run from the package root so lib/ is visible',
  );
  final files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
  // Guard against a silently-empty glob, which would make every scan vacuous.
  expect(
    files.length,
    greaterThan(20),
    reason:
        'expected to scan the whole package; found only ${files.length} '
        'dart files under lib/ — the glob is broken, not the code clean',
  );
  return files;
}

List<Violation> scanLib() {
  final all = <Violation>[];
  for (final f in libDartFiles()) {
    all.addAll(scanSource(f.path, f.readAsStringSync()));
  }
  return all;
}

void main() {
  group('D6 gate — no tokens in callback URLs anywhere under lib/', () {
    test('item 1: no file reads access_token out of a callback URL', () {
      final v = scanLib()
          .where((x) => x.text.contains('access_token'))
          .where((x) => x.reason.startsWith('reads'))
          .toList();
      expect(
        v,
        isEmpty,
        reason:
            'SECURITY REGRESSION (AOID SDK-08 / D6): an access token is '
            'being read out of a URL. The callback carries a ?code= which '
            'must be exchanged over POST for tokens in a response BODY. '
            'Fix the call site; do not relax this gate.\n'
            '${v.join('\n')}',
      );
    });

    test('item 2: no file reads refresh_token out of a callback URL', () {
      final v = scanLib()
          .where((x) => x.text.contains('refresh_token'))
          .where((x) => x.reason.startsWith('reads'))
          .toList();
      expect(
        v,
        isEmpty,
        reason:
            'SECURITY REGRESSION (AOID SDK-08 / D6): a refresh token is '
            'being read out of a URL — the worst of the two, since it is '
            'long-lived. Exchange the ?code= over POST instead.\n'
            '${v.join('\n')}',
      );
    });

    test('item 4: no file CONSTRUCTS a URL containing a token', () {
      final v = scanLib().where((x) => x.reason.startsWith('builds')).toList();
      expect(
        v,
        isEmpty,
        reason:
            'SECURITY REGRESSION (AOID SDK-08 / D6): the SDK is building '
            'a URL with a token in it — the exact pattern eden-platform-go '
            'the server removed from the server. Tokens go in POST bodies.\n'
            '${v.join('\n')}',
      );
    });

    // POSITIVE CONTROL. Without this, items 1/2/4 pass whenever the glob
    // matches nothing or the regexes are silently broken.
    test('item 3: the gate CAN fail — the same predicate detects a planted '
        'violation', () {
      const planted = '''
class Leaky {
  static Session fromCallback(String callbackUrl) {
    final uri = Uri.parse(callbackUrl);
    final accessToken = uri.queryParameters['access_token'];
    final refreshToken = uri.queryParameters['refresh_token'];
    final legacy = params['access_token'];
    final url = 'https://host/cb?access_token=\$accessToken';
    return Session(accessToken, refreshToken, legacy, url);
  }
}
''';
      final v = scanSource('planted_fixture.dart', planted);

      expect(
        v,
        isNotEmpty,
        reason:
            'the gate detected nothing in a file that '
            'is nothing but violations — the predicate is broken',
      );
      expect(
        v.where((x) => x.reason.startsWith('reads')),
        hasLength(3),
        reason: 'expected both queryParameters reads and the params read',
      );
      expect(
        v.where((x) => x.reason.startsWith('builds')),
        isNotEmpty,
        reason: 'the write-side pattern did not fire on access_token=',
      );
      expect(v.map((x) => x.text).join(), contains('access_token'));
    });

    // Negative control: the CORRECT pattern must NOT trip the gate, or the
    // gate would be unusable and someone would weaken it.
    test('the gate does NOT fire on the correct code-exchange pattern', () {
      const correct = '''
final decoded = jsonDecode(response.body) as Map<String, dynamic>;
final access = decoded['access_token'];
final refresh = decoded['refresh_token'];
/// - success: `200` `application/json` `{"access_token":"...","refresh_token":"..."}`
final code = uri.queryParameters['code'];
final state = uri.queryParameters['state'];
''';
      expect(
        scanSource('correct.dart', correct),
        isEmpty,
        reason:
            'reading a token from a JSON response BODY is the required '
            'behaviour, not a violation — a gate that flags it will be '
            'weakened by the next person, which is how gates die',
      );
    });

    test('the deleted Process.run browser launcher has not come back', () {
      final offenders = <Violation>[];
      for (final f in libDartFiles()) {
        final lines = f.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (_isCommentLine(lines[i])) continue;
          if (lines[i].contains('Process.run')) {
            offenders.add(
              Violation(
                f.path,
                i + 1,
                lines[i],
                'shells out to launch a browser',
              ),
            );
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'the SSO removal deleted SSOAuthService partly because '
            "Process.run('cmd', ['/c','start', url]) with a URL taken from a "
            'redirect is a shell-injection-shaped surface. Use '
            'flutter_web_auth_2.\n${offenders.join('\n')}',
      );
    });
  });
}
