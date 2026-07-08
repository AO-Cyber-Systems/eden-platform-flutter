import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

/// An RFC 7636 PKCE material set for a single authorization request,
/// bundled with the CSRF `state` and OIDC `nonce` for the same request.
class PkcePair {
  const PkcePair({
    required this.codeVerifier,
    required this.codeChallenge,
    required this.state,
    required this.nonce,
  });

  /// RFC 7636 code_verifier (43-128 chars, unreserved set).
  final String codeVerifier;

  /// RFC 7636 S256 code_challenge (unpadded base64url).
  final String codeChallenge;

  /// CSRF `state` — >=128 bits of secure randomness, url-safe.
  final String state;

  /// OIDC `nonce` — >=128 bits of secure randomness, url-safe.
  final String nonce;
}

/// RFC 7636 (PKCE, S256) code_verifier / code_challenge helpers.
class PkceGenerator {
  PkceGenerator._();

  /// RFC 7636 §4.1 code_verifier length bounds.
  static const int _minVerifierLength = 43;
  static const int _maxVerifierLength = 128;

  static final Random _rng = Random.secure();

  /// Unpadded base64url per RFC 7636 §4.2 / RFC 4648 §5 (no `=` padding).
  static String _b64UrlNoPad(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');

  /// [byteCount] cryptographically-random bytes as unpadded base64url.
  static String _randomUrlSafe(int byteCount) {
    final bytes =
        List<int>.generate(byteCount, (_) => _rng.nextInt(256), growable: false);
    return _b64UrlNoPad(bytes);
  }

  /// S256 code_challenge = base64url-nopad(SHA-256(ASCII(verifier))).
  ///
  /// Throws [ArgumentError] if [verifier] is outside the RFC 7636 §4.1
  /// length range of 43-128 characters.
  static String codeChallengeFor(String verifier) {
    if (verifier.length < _minVerifierLength ||
        verifier.length > _maxVerifierLength) {
      throw ArgumentError.value(
        verifier.length,
        'verifier.length',
        'code_verifier length must be $_minVerifierLength-$_maxVerifierLength '
            '(RFC 7636 §4.1)',
      );
    }
    return _b64UrlNoPad(sha256.convert(ascii.encode(verifier)).bytes);
  }

  /// Produce a fresh PKCE pair (+ CSRF state, OIDC nonce) from secure
  /// randomness.
  ///
  /// - verifier: 64 random bytes -> 86-char base64url-nopad (within 43-128).
  /// - state / nonce: 16 random bytes -> 22-char base64url-nopad (>=128 bits).
  static PkcePair generate() {
    final verifier = _randomUrlSafe(64);
    return PkcePair(
      codeVerifier: verifier,
      codeChallenge: codeChallengeFor(verifier),
      state: _randomUrlSafe(16),
      nonce: _randomUrlSafe(16),
    );
  }
}
