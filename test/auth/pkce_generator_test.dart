// Narrow in-package import (not the eden_platform.dart barrel): the barrel
// re-exports src/networking/*.dart, which at the resolved dio 5.10.0 fails to
// compile under the CFE (DioExceptionType.transformTimeout was added upstream,
// the package's ^5.9.0 switch statements predate it). `flutter analyze` skips
// that, but `flutter test` compiles it. PkceGenerator has no networking
// dependency, so importing it directly keeps this suite green regardless.
import 'package:eden_platform_flutter/src/aoid/pkce.dart';
import 'package:flutter_test/flutter_test.dart';

// RFC 7636 unreserved verifier charset: ALPHA / DIGIT / "-" / "." / "_" / "~".
final _verifierCharset = RegExp(r'^[A-Za-z0-9\-._~]+$');
// base64url-nopad alphabet (state / nonce).
final _urlSafe = RegExp(r'^[A-Za-z0-9\-_]+$');

void main() {
  group('PkceGenerator.codeChallengeFor', () {
    test('returns RFC 7636 Appendix B known-answer challenge (S256)', () {
      // RFC 7636 Appendix B fixed vector — hand-copied, do NOT regenerate.
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      const expectedChallenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';

      expect(PkceGenerator.codeChallengeFor(verifier), expectedChallenge);
    });

    test('throws ArgumentError for empty / too-short / too-long verifier', () {
      expect(() => PkceGenerator.codeChallengeFor(''), throwsArgumentError);
      // 42 chars — one below the RFC 7636 §4.1 minimum of 43.
      expect(() => PkceGenerator.codeChallengeFor('a' * 42),
          throwsArgumentError);
      // 129 chars — one above the RFC 7636 §4.1 maximum of 128.
      expect(() => PkceGenerator.codeChallengeFor('a' * 129),
          throwsArgumentError);
    });
  });

  group('PkceGenerator.generate', () {
    test('codeVerifier is 43-128 chars from the RFC 7636 unreserved set', () {
      final pair = PkceGenerator.generate();
      expect(pair.codeVerifier.length, inInclusiveRange(43, 128));
      expect(_verifierCharset.hasMatch(pair.codeVerifier), isTrue);
    });

    test('codeChallenge == codeChallengeFor(codeVerifier)', () {
      final pair = PkceGenerator.generate();
      expect(pair.codeChallenge,
          PkceGenerator.codeChallengeFor(pair.codeVerifier));
      // Challenge must be unpadded base64url.
      expect(pair.codeChallenge.contains('='), isFalse);
    });

    test('state and nonce are url-safe and >=22 chars (>=128 bits)', () {
      final pair = PkceGenerator.generate();
      expect(pair.state.length, greaterThanOrEqualTo(22));
      expect(pair.nonce.length, greaterThanOrEqualTo(22));
      expect(_urlSafe.hasMatch(pair.state), isTrue);
      expect(_urlSafe.hasMatch(pair.nonce), isTrue);
    });

    test('successive calls differ in verifier, state and nonce', () {
      final a = PkceGenerator.generate();
      final b = PkceGenerator.generate();
      expect(a.codeVerifier, isNot(b.codeVerifier));
      expect(a.state, isNot(b.state));
      expect(a.nonce, isNot(b.nonce));
    });
  });
}
