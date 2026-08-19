// AoidMemoryTokenStore — the AOID module's WEB DEFAULT token store.
//
// RIVERPOD-FREE BY CONSTRUCTION (see aoid_token_store.dart's header).

import 'aoid_token_store.dart';

/// Holds an access token in memory and **cannot** hold a refresh token.
///
/// This is the store `aoidTokenStoreFor` returns for every posture on web, and
/// for Modes A and C on native. The access token lives in a private field for
/// the lifetime of the isolate and is never written to any storage API — not
/// `flutter_secure_storage`, not `shared_preferences`, not `localStorage`.
///
/// **[writeRefreshToken] with a non-null value THROWS.** That is not an
/// oversight and not defensiveness-for-its-own-sake:
///
/// > A silent no-op produces a session that mysteriously fails to restore. The
/// > next engineer debugs it as a persistence bug, re-adds the write, and the
/// > exposure the design notes C3 documents comes straight back. A throw fails at
/// > the point of the mistake and names the remedy.
///
/// Passing `null` is always legal — logout must be able to clear
/// unconditionally.
class AoidMemoryTokenStore implements AoidTokenStore {
  String? _accessToken;

  @override
  Future<String?> readAccessToken() async => _accessToken;

  @override
  Future<void> writeAccessToken(String? value) async {
    _accessToken = value;
  }

  @override
  Future<void> writeRefreshToken(String? value) async {
    // Clearing is ALWAYS legal. Logout, best-effort wipes and the AOID
    // strategy's web path all call this with null; making that throw would
    // strand tokens rather than protect them.
    if (value == null) return;

    throw UnsupportedError(
      'AOID refresh tokens are never held by a web client. '
      'Use Mode A: hand the authorization code to your own backend, which '
      'holds the client secret and sets an httpOnly SameSite cookie. '
      'This throws rather than silently dropping the write, because a silent '
      'drop looks like a session-restore bug and invites re-adding it.',
    );
  }

  @override
  Future<String?> readRefreshToken() async => null;

  @override
  Future<void> clear() async {
    _accessToken = null;
  }
}
