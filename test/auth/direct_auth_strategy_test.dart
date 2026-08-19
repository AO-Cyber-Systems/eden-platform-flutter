import 'package:flutter_test/flutter_test.dart';

import 'package:eden_platform_flutter/eden_platform.dart';

/// Direct authentication (PLAT-02, #22).
///
/// The application authenticates against its OWN backend and holds the
/// resulting session. No issuer, no browser hop, no second factor.
///
/// This behaviour already existed — but only as the fallback `AuthNotifier`
/// takes when NO strategy is injected. That made it unselectable: an app
/// could not say "use direct" the way it can say "use the redirect flow".
/// Expressing it as a strategy is what makes the mode a configuration choice
/// rather than a property of having left something unconfigured.

class _FakeRepo implements PlatformRepository {
  _FakeRepo({this.session, this.error});
  final PlatformSession? session;
  final Object? error;
  int loginCalls = 0;
  String? lastEmail;
  String? lastPassword;
  String? loggedOutWith;

  @override
  Future<PlatformSession> login(String email, String password) async {
    loginCalls++;
    lastEmail = email;
    lastPassword = password;
    if (error != null) throw error!;
    return session!;
  }

  @override
  Future<void> logout(String refreshToken) async {
    loggedOutWith = refreshToken;
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

PlatformSession _session() => const PlatformSession(
  accessToken: 'at-1',
  refreshToken: 'rt-1',
  user: PlatformUser(
    id: 'u-1',
    email: 'a@b.c',
    displayName: 'A B',
    isActive: true,
  ),
);

void main() {
  group('DirectAuthStrategy', () {
    test('a successful login yields Authenticated with the backend session', () async {
      final repo = _FakeRepo(session: _session());
      final s = DirectAuthStrategy(repository: repo);

      final r = await s.initiateLogin({'email': 'a@b.c', 'password': 'pw'});

      expect(r, isA<Authenticated>());
      expect((r as Authenticated).session.accessToken, 'at-1');
      expect(repo.lastEmail, 'a@b.c');
      expect(repo.lastPassword, 'pw');
    });

    test('a rejected login yields Failed, never a thrown exception', () async {
      final s = DirectAuthStrategy(repository: _FakeRepo(error: Exception('nope')));

      final r = await s.initiateLogin({'email': 'a@b.c', 'password': 'bad'});

      expect(
        r,
        isA<Failed>(),
        reason: 'AuthNotifier drives its state machine off AuthResult; a strategy '
            'that throws bypasses that machine entirely',
      );
    });

    test('an EMPTY password fails without calling the backend', () async {
      // Distinct from the absent-password case: a form submitting '' for an
      // untouched field is the common shape, and null-safety does not catch it.
      final repo = _FakeRepo(session: _session());
      final s = DirectAuthStrategy(repository: repo);

      final r = await s.initiateLogin(const {'email': 'a@b.c', 'password': ''});

      expect(r, isA<Failed>());
      expect(repo.loginCalls, 0);
    });

    test('missing credentials fail without calling the backend', () async {
      final repo = _FakeRepo(session: _session());
      final s = DirectAuthStrategy(repository: repo);

      final r = await s.initiateLogin(const {'email': 'a@b.c'});

      expect(r, isA<Failed>());
      expect(
        repo.loginCalls,
        0,
        reason: 'a half-filled form should not spend an authentication attempt — '
            'backends rate-limit these',
      );
    });

    test('completeLogin fails: direct login is single-step by construction', () async {
      final s = DirectAuthStrategy(repository: _FakeRepo(session: _session()));

      expect(await s.completeLogin('tok', const {'totp': '123456'}), isA<Failed>());
    });

    test('restoreSession returns null when no session was stored', () async {
      final s = DirectAuthStrategy(repository: _FakeRepo(session: _session()));

      expect(await s.restoreSession(), isNull);
    });

    test('logout never throws when the backend rejects it', () async {
      final s = DirectAuthStrategy(
        repository: _FakeRepo(session: _session(), error: Exception('boom')),
      );

      // Must complete. A failed server-side revoke cannot trap a user in a
      // session they have asked to leave.
      await s.logout();
    });
  });
}
