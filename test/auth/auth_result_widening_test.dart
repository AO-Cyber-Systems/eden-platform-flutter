// Proves AOID objective 50 TRD 50-04: the `AuthResult` sealed family is
// widened ADDITIVELY to carry what objective 49's `/oauth/native/*` ceremony
// actually returns.
//
// The two shapes being added, verbatim from 49-08-SUMMARY.md's wire table:
//
//   mid-ceremony  401 {"error":"insufficient_authorization", "auth_session":"<NEW>",
//                      "next":"mfa", "available_methods":[...]}
//   hosted hop    400 {"error":"redirect_to_web", "error_description":"...",
//                      "authorization_url":"..."}
//
// Everything here imports through the PUBLIC barrel, not `src/`, because the
// thing under test is the surface 18 packages consume.

import 'dart:io';

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FactorRequired', () {
    test('carries continuationToken, next and availableMethods, and is '
        'const constructible', () {
      const FactorRequired result = FactorRequired(
        continuationToken: 'as_rotated_2',
        next: 'mfa',
        availableMethods: ['totp', 'backup_code', 'webauthn'],
      );

      expect(result.continuationToken, 'as_rotated_2');
      expect(result.next, 'mfa');
      expect(result.availableMethods, ['totp', 'backup_code', 'webauthn']);
      // It is a member of the sealed family, so the one switch must handle it.
      expect(result, isA<AuthResult>());
    });

    test('availableMethods defaults to empty — objective 49 deliberately does '
        'not emit available_methods before a factor has succeeded (49-07: '
        'pre-success emission makes the endpoint an enumeration oracle)', () {
      const FactorRequired result = FactorRequired(
        continuationToken: 'as_1',
        next: 'password',
      );

      expect(result.availableMethods, isEmpty);
    });
  });

  group('RedirectRequired', () {
    test('carries an authorizationUrl (Uri) and an optional reason, and is '
        'const constructible', () {
      final RedirectRequired result = RedirectRequired(
        Uri.parse(
          'https://auth.aocyber.ai/oauth/authorize'
          '?client_id=aodex&response_type=code',
        ),
        reason: 'redirect_to_web',
      );

      expect(result.authorizationUrl, isA<Uri>());
      expect(result.authorizationUrl.host, 'auth.aocyber.ai');
      expect(result.authorizationUrl.path, '/oauth/authorize');
      expect(result.reason, 'redirect_to_web');
      expect(result, isA<AuthResult>());
    });

    test('reason is optional — a caller that has nothing to log omits it', () {
      final RedirectRequired result = RedirectRequired(
        Uri.parse('https://auth.aocyber.ai/oauth/authorize'),
      );

      expect(result.reason, isNull);
    });

    test('is NOT a Failed — a browser hop is a first-class path, not an error '
        '(50-CONTEXT.md D7)', () {
      final AuthResult result = RedirectRequired(
        Uri.parse('https://auth.aocyber.ai/oauth/authorize'),
      );

      expect(result, isNot(isA<Failed>()));
      expect(result, isA<RedirectRequired>());
    });
  });

  group('source compatibility with existing implementors (D8: additive)', () {
    test('const TwoFactorRequired(String) still compiles and constructs — the '
        'exact form AOID\'s portal uses at aoid_auth_strategy.dart:133', () {
      // Verbatim from ~/dev/aoid/portal/lib/src/auth/aoid_auth_strategy.dart:
      //   const _kAoidMfaContinuationToken = 'aoid:mfa-cookie-bound';   (:100)
      //   return const eden.TwoFactorRequired(_kAoidMfaContinuationToken); (:133)
      // If this stops compiling, the widening is NOT additive and the portal
      // breaks. Hand-written, not generated (no_llm_test_data).
      const String kAoidMfaContinuationToken = 'aoid:mfa-cookie-bound';
      // ignore: deprecated_member_use_from_same_package
      const AuthResult result = TwoFactorRequired(kAoidMfaContinuationToken);

      expect(result, isA<AuthResult>());
      // The portal's `isAwaitingMfa` extension string-compares the sentinel
      // off AuthNotifier.continuationToken, so the value must survive intact.
      // ignore: deprecated_member_use_from_same_package
      expect(
        (result as TwoFactorRequired).continuationToken,
        'aoid:mfa-cookie-bound',
      );
    });

    test('a whole AuthStrategy implementor written against the OLD family '
        'still satisfies the interface unchanged', () async {
      // Replicates the shape of the portal's AoidAuthStrategy: implements the
      // interface, returns only pre-widening cases, never switches on the
      // family. If the widening had changed a signature or removed a case,
      // this class would not compile.
      final _LegacyImplementor strategy = _LegacyImplementor();

      final AuthResult initiated = await strategy.initiateLogin(
        <String, String>{'email': 'a@b.com'},
      );
      // ignore: deprecated_member_use_from_same_package
      expect(initiated, isA<TwoFactorRequired>());

      final AuthResult completed = await strategy.completeLogin(
        'aoid:mfa-cookie-bound',
        <String, String>{'totp': '1'},
      );
      expect(completed, isA<Failed>());
      expect(await strategy.restoreSession(), isNull);
      await strategy.logout();
      expect(strategy.logoutCalls, 1);
    });

    test('TwoFactorRequired IS-A FactorRequired, with next == "mfa" and an '
        'empty availableMethods — so a `case FactorRequired(...)` arm matches '
        'the portal\'s deprecated construction', () {
      // ignore: deprecated_member_use_from_same_package
      const AuthResult result = TwoFactorRequired('aoid:mfa-cookie-bound');

      expect(result, isA<FactorRequired>());
      final FactorRequired widened = result as FactorRequired;
      expect(widened.continuationToken, 'aoid:mfa-cookie-bound');
      expect(widened.next, 'mfa');
      expect(widened.availableMethods, isEmpty);
    });
  });

  group('the family is genuinely sealed and complete', () {
    // A switch with NO `default:`. If AuthResult gains a case that these four
    // arms do not cover, this stops COMPILING — which is the whole point of a
    // sealed family. A `default:` here would silently absorb the new case and
    // destroy that property.
    String classify(AuthResult result) {
      switch (result) {
        case Authenticated():
          return 'authenticated';
        case FactorRequired():
          return 'factor';
        case RedirectRequired():
          return 'redirect';
        case Failed():
          return 'failed';
      }
    }

    const PlatformUser user = PlatformUser(
      id: 'u-1',
      email: 'a@b.com',
      displayName: 'A',
      isActive: true,
    );

    test('every arm is reachable with a hand-built instance', () {
      expect(
        classify(Authenticated(PlatformSession.cookieBound(user: user))),
        'authenticated',
      );
      expect(
        classify(
          const FactorRequired(
            continuationToken: 'as_2',
            next: 'mfa',
            availableMethods: ['totp'],
          ),
        ),
        'factor',
      );
      expect(
        classify(
          RedirectRequired(
            Uri.parse('https://auth.aocyber.ai/oauth/authorize'),
          ),
        ),
        'redirect',
      );
      expect(classify(const Failed('bad credentials')), 'failed');
    });

    test('the deprecated TwoFactorRequired lands in the FactorRequired arm, '
        'so no consumer needs a second arm for it', () {
      // ignore: deprecated_member_use_from_same_package
      expect(
        classify(const TwoFactorRequired('aoid:mfa-cookie-bound')),
        'factor',
      );
    });
  });

  group('source-level contracts', () {
    // These read the shipped source. They are cheap guards against a future
    // edit quietly deleting a contract that only exists as prose — the
    // rotation rule and the telemetry-only rule are both unenforceable at
    // runtime, so the source text IS the artifact.
    final File strategySource = File('lib/src/auth/auth_strategy.dart');
    final File providerSource = File('lib/src/auth/auth_provider.dart');

    test('the source files under test are actually readable from the test '
        'working directory', () {
      // Without this, every gate below would vacuously pass on an empty read.
      expect(
        strategySource.existsSync(),
        isTrue,
        reason: 'run `flutter test` from the package root',
      );
      expect(providerSource.existsSync(), isTrue);
      expect(
        strategySource.readAsStringSync(),
        contains('sealed class AuthResult'),
      );
    });

    test('RedirectRequired.reason is documented TELEMETRY ONLY — objective '
        '49\'s error mapper is deliberately lossy so the client cannot become '
        'an account-existence or tenancy-tier oracle (49-04)', () {
      final String source = strategySource.readAsStringSync();
      // Scope the assertion to RedirectRequired's own declaration, so the
      // warning cannot drift onto an unrelated class and still pass.
      final int start = source.indexOf('class RedirectRequired');
      expect(start, greaterThan(-1));
      final int declEnd = source.indexOf('}', start);
      // The doc comment sits ABOVE the class, so search back to the previous
      // blank-line-separated block as well.
      final int docStart = source.lastIndexOf(
        '/// This factor cannot be',
        start,
      );
      expect(
        docStart,
        greaterThan(-1),
        reason: 'RedirectRequired lost its doc comment',
      );
      final String decl = source.substring(docStart, declEnd);

      expect(decl, contains('TELEMETRY ONLY'));
      expect(decl, contains('Never branch UI on this'));
      expect(
        decl,
        contains('D7'),
        reason: 'the "not an error" rule must cite 50-CONTEXT.md D7',
      );
    });

    test('the auth_session rotation contract is written into the source, not '
        'only into the TRD (49-06)', () {
      final String strategy = strategySource.readAsStringSync();
      final int start = strategy.indexOf('class FactorRequired');
      expect(start, greaterThan(-1));
      final int docStart = strategy.lastIndexOf(
        '/// The server needs another factor',
        start,
      );
      expect(docStart, greaterThan(-1));
      final String decl = strategy.substring(docStart, start);

      expect(decl, contains('MUST replace their stored handle'));
      expect(decl, contains('49-06'));
      expect(decl, contains('invalid_session'));

      // And the capture site itself carries the reason it may not be deleted.
      final String provider = providerSource.readAsStringSync();
      expect(provider, contains('49-06'));
    });

    test('no third spelling: the wire code is redirect_to_web per 49-04, and '
        '50-CONTEXT D8\'s informal `redirect_required` must not leak into the '
        'source', () {
      expect(
        strategySource.readAsStringSync(),
        isNot(contains('redirect_required')),
      );
      expect(
        providerSource.readAsStringSync(),
        isNot(contains('redirect_required')),
      );
      // The draft spelling IS present, as the documented wire origin.
      expect(strategySource.readAsStringSync(), contains('redirect_to_web'));
    });
  });
}

/// Hand-built implementor written ONLY against the pre-widening family. Its
/// job is to fail to compile if the widening is subtractive.
class _LegacyImplementor implements AuthStrategy {
  int logoutCalls = 0;

  @override
  Future<AuthResult> initiateLogin(Map<String, String> credentials) async {
    // ignore: deprecated_member_use_from_same_package
    return const TwoFactorRequired('aoid:mfa-cookie-bound');
  }

  @override
  Future<AuthResult> completeLogin(
    String continuationToken,
    Map<String, String> proof,
  ) async {
    return const Failed('TOTP code is required.');
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
  }

  @override
  Future<PlatformSession?> restoreSession() async => null;
}
