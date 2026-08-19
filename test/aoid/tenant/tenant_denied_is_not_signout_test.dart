// the spec, task 1 — THE REQUIRED MULTI-TENANT ISOLATION GATE
// (`wrong_tenant_assertion`, enforcement: required).
//
// The bug this file exists to prevent, stated once:
//
//   AOID answers a switch to a tenant you are NOT a member of with a GENERIC
//   `invalid_grant` (the token service). Wire that
//   naively into AuthNotifier.restoreSession's `on AuthError` arm
//   (auth_provider.dart:410-413 -> _clearPersistedTokens() + unauthenticated)
//   or into AODex's Dio 401 interceptor
//   (aodex/flutter/lib/src/features/auth/application/auth_service.dart:139-147
//   -> forceUnauthenticated()) and ASKING ABOUT A WORKSPACE YOU ARE NOT IN
//   SIGNS YOU OUT.
//
// A denial is a PERMISSION answer, not a SESSION answer.
//
// TEST LIST (written first; RED before GREEN, one at a time).
//
// Fixture non-vacuity — these drive the FAKE directly, before any client
// exists. Without them the client's own assertions pass for the wrong reason:
//   F1  the fake serves the refresh grant and ROTATES the refresh token
//   F2  the membership gate is NON-CONSUMING: a denied switch leaves the
//       presented refresh token LIVE (the token service reads the row
//       without consuming it precisely so a bad target does not burn it)
//   F3  a denied switch and a genuinely bad refresh token are BYTE-IDENTICAL
//       — status, every header, and the raw body. If the FAKE distinguished
//       them, item 12's opacity assertion would pass vacuously and the client
//       could "disambiguate" by reading a discriminator that production does
//       not send.
//
// Client (task 1):
//   1   refresh(activeTenant:) sends `active_tenant` IN THE FORM BODY, with
//       the slug value (the token endpoint)
//   2   NO custom header is sent — the outgoing header map carries only the
//       content type. That is the CORS simple-request guard: verified live
//       2026-08-01, /oauth/token answers preflight 204 with ACAO:* and no
//       Allow-Credentials. An `X-Active-Tenant` header would break every
//       browser caller.
//   10  POSITIVE CONTROL (written BEFORE item 9): a switch to a tenant the
//       user IS a member of succeeds, and the NEW ACCESS token's `tnt` is the
//       requested slug. Without this, item 9 passes because the switch failed
//       for any reason at all.
//   9   a switch to a NON-MEMBER tenant yields AoidTenantDenied — and the
//       app's realistic sign-out handler does NOT fire: AuthNotifier's
//       state.status is UNCHANGED, the stored tokens are UNTOUCHED, and the
//       user is still authenticated. Asserted on the NOTIFIER'S STATE, not
//       merely on the thrown type: a correct type that still reaches a
//       clearing path is the bug, not the fix.
//   9c  POSITIVE CONTROL for item 9's handler: the SAME handler given a real
//       AuthError DOES clear tokens and sign out. Without it, item 9 passes
//       because the handler is inert.
//   11  a denied switch does not burn the refresh token — the same refresh
//       token succeeds on an ordinary refresh immediately afterwards
//   12  the denial carries NO reason detail: neither the target slug, nor a
//       membership verdict, nor the server's own error/error_description
//       appears anywhere in the thrown object
//   13  the retry DECISION (riverpod-3 checklist item 4): a denial is a
//       refusal, not a transient failure, so aoidTenantSwitchRetry declines
//       to retry it — while still allowing a bounded retry for a genuine
//       transport blip
//
// FIXTURES ARE INLINE (resolved intent: fixture_strategy: inline) and
// HAND-BUILT (no_llm_test_data). The JWT assembly and the tenant identifiers
// are reused from the spec fixture module rather than re-invented, so the
// decoded claims are trustworthy and the slug/UUID pairing cannot drift.
//
// The shared test/auth/fixtures/fake_aoid_endpoint.dart is deliberately NOT
// extended here: the spec and the spec are running against it concurrently, and this
// the spec's fake models a DIFFERENT contract (the refresh grant's membership gate,
// not the native ceremony).

import 'dart:convert';

import 'package:eden_platform_flutter/eden_platform.dart';
// AuthError is not on the barrel's export surface; the sign-out handler below
// has to name it, because it is the exact type AuthNotifier.restoreSession
// keys its `_clearPersistedTokens() + unauthenticated` arm on.
import 'package:eden_platform_flutter/src/errors/platform_errors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../claims/fixtures/aoid_claim_fixtures.dart';

const _issuer = 'https://auth.fake-aoid.test';
const _clientId = 'aodex-flutter';

/// A tenant the identity is NOT a member of. Its slug never reaches a token.
const _outsiderSlug = 'initech';

// ---------------------------------------------------------------------------
// THE FAKE — aoid /oauth/token, refresh grant, with the membership gate.
//
// Modelled on the token service
//:882-885  a NON-CONSUMING read of the refresh row, so a bad target does
//             not burn the token
//:886-914  the membership check; non-member -> auth.active_tenant.denied
//             audit + a GENERIC invalid_grant
//:922-928  `tnt` = the validated target's SLUG, else home
// ---------------------------------------------------------------------------

/// One recorded request: exactly what the client put on the wire.
class _Recorded {
  _Recorded({
    required this.headers,
    required this.rawBody,
    required this.fields,
  });

  /// The header map as `package:http` handed it to the transport. Item 2
  /// asserts on its KEY SET — that is the whole CORS simple-request contract.
  final Map<String, String> headers;
  final String rawBody;
  final Map<String, String> fields;
}

class _FakeAoidTokenEndpoint {
  _FakeAoidTokenEndpoint({required this.memberOf});

  /// The slugs this identity is a member of. Anything else is denied.
  final Set<String> memberOf;

  final List<_Recorded> requests = [];

  /// The ONE refresh token the fake will accept. Rotates on every grant that
  /// actually reaches the issuing path — and NOT on a denial.
  String liveRefreshToken = 'refresh-token-0001';

  /// Every refresh token minted, in order. `[0]` is the seed.
  final List<String> mintedRefreshTokens = ['refresh-token-0001'];

  int _seq = 1;

  /// The ONE function that renders `invalid_grant`. A denied switch and a
  /// genuinely bad refresh token BOTH go through it, so byte-identity is
  /// structural rather than two coincidentally-equal literals. AOID collapses
  /// them on purpose (the token service): distinguishing them would make the
  /// endpoint a membership oracle.
  http.Response _invalidGrant() => http.Response(
    jsonEncode({
      'error': 'invalid_grant',
      'error_description': 'invalid or expired refresh token',
    }),
    400,
    headers: const {
      'content-type': 'application/json',
      'cache-control': 'no-store',
      'pragma': 'no-cache',
    },
  );

  http.Client get client => MockClient((request) async {
    if (request.method != 'POST' ||
        !request.url.path.endsWith('/oauth/token')) {
      return http.Response('{"error":"not_found"}', 404);
    }
    final fields = request.body.isEmpty
        ? <String, String>{}
        : Uri.splitQueryString(request.body);
    requests.add(
      _Recorded(
        headers: Map<String, String>.from(request.headers),
        rawBody: request.body,
        fields: fields,
      ),
    );

    if (fields['grant_type'] != 'refresh_token') return _invalidGrant();

    // the token service — a NON-CONSUMING read. Nothing below this line
    // rotates the token until the grant is actually issued.
    if (fields['refresh_token'] != liveRefreshToken) return _invalidGrant();

    final target = fields['active_tenant'];
    if (target != null && !memberOf.contains(target)) {
      // the token service — audit, then a GENERIC invalid_grant. The
      // presented refresh token is STILL LIVE.
      return _invalidGrant();
    }

    _seq += 1;
    liveRefreshToken = 'refresh-token-${_seq.toString().padLeft(4, '0')}';
    mintedRefreshTokens.add(liveRefreshToken);

    // the token service — tnt is the validated target's SLUG, else home.
    // GID-14: with no active selection the access token's tnt is the HOME
    // tenant's SLUG, still never the UUID.
    final tnt = target ?? homeTenantSlug;
    return http.Response(
      jsonEncode({
        'access_token': buildJwt({
          'iss': _issuer,
          'sub': identitySubject,
          'aud': _clientId,
          'exp': expEpochSeconds,
          'iat': iatEpochSeconds,
          'tnt': tnt,
          'scope': 'openid profile',
          'client_id': _clientId,
          'aal': 'aal2',
          'ent': ['tenant.admin'],
        }),
        'refresh_token': liveRefreshToken,
        // The id_token's tnt is the HOME tenant UUID and does NOT follow the
        // switch (the token claims). Present so a client
        // that verified the switch by decoding the id_token would FAIL here.
        'id_token': idTokenHomeTenant,
        'token_type': 'Bearer',
        'expires_in': 900,
      }),
      200,
      headers: const {
        'content-type': 'application/json',
        'cache-control': 'no-store',
      },
    );
  });
}

AoidTokenClient _clientFor(_FakeAoidTokenEndpoint fake) => AoidTokenClient(
  endpoints: AoidEndpoints.parse(_issuer),
  httpClient: fake.client,
  clientId: _clientId,
);

// ---------------------------------------------------------------------------
// A LIVE, AUTHENTICATED SESSION — so item 9 can assert on the NOTIFIER'S
// STATE rather than only on the thrown type.
//
// Item 9 is worthless without something that COULD sign the user out. The
// handler below is that something: it reproduces the two real sign-out paths
// this the spec exists to route around, and item 9c proves it genuinely bites.
// ---------------------------------------------------------------------------

const _seedRefreshToken = 'refresh-token-0001';

class _FakeTokenStorage implements TokenStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> readAccessToken() async => values['access'];
  @override
  Future<String?> readRefreshToken() async => values['refresh'];
  @override
  Future<void> writeAccessToken(String? value) async {
    if (value == null) {
      values.remove('access');
    } else {
      values['access'] = value;
    }
  }

  @override
  Future<void> writeRefreshToken(String? value) async {
    if (value == null) {
      values.remove('refresh');
    } else {
      values['refresh'] = value;
    }
  }

  @override
  Future<void> clear() async => values.clear();
}

/// Restores a bearer session from the seeded storage. Nothing more.
class _FakeStrategy implements AuthStrategy {
  _FakeStrategy(this.storage);

  final _FakeTokenStorage storage;

  @override
  Future<PlatformSession?> restoreSession() async {
    final refresh = storage.values['refresh'];
    if (refresh == null) return null;
    return PlatformSession(
      accessToken: storage.values['access'] ?? '',
      refreshToken: refresh,
      user: const PlatformUser(
        id: identitySubject,
        email: 'ada@acme.example',
        displayName: 'Ada Lovelace',
        isActive: true,
      ),
    );
  }

  @override
  Future<AuthResult> initiateLogin(Map<String, String> credentials) async =>
      throw UnimplementedError();
  @override
  Future<AuthResult> completeLogin(String t, Map<String, String> p) async =>
      throw UnimplementedError();
  @override
  Future<void> logout() async {}
}

/// Never called. Present only so `authProvider`'s build does not construct the
/// real Connect transport.
class _StubRepository implements PlatformRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_StubRepository.${invocation.memberName}');
}

/// A live, authenticated riverpod scope wrapping [AuthNotifier].
class _LiveSession {
  _LiveSession._(this.container, this.storage);

  final ProviderContainer container;
  final _FakeTokenStorage storage;

  /// riverpod-3 migration checklist item 9a: a `Notifier`'s `state` DOES NOT
  /// EXIST until the provider is first READ, and touching it early throws
  /// `Bad state: Tried to use a notifier in an uninitialized state` at RUNTIME
  /// only — it compiles and passes `flutter analyze`. So every read here goes
  /// THROUGH the container; nothing holds a notifier instance and reaches into
  /// `.state`.
  static Future<_LiveSession> start() async {
    final storage = _FakeTokenStorage()
      ..values['refresh'] = _seedRefreshToken
      ..values['access'] = accessTokenNoActiveSelection;
    final container = ProviderContainer(
      overrides: [
        tokenStorageProvider.overrideWithValue(storage),
        platformRepositoryProvider.overrideWithValue(_StubRepository()),
        authStrategyProvider.overrideWithValue(_FakeStrategy(storage)),
      ],
    );
    // READ FIRST — this is what initializes the notifier (item 9a).
    container.read(authProvider);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
      if (container.read(authProvider).status == AuthStatus.authenticated) {
        break;
      }
    }
    return _LiveSession._(container, storage);
  }

  AuthStatus get status => container.read(authProvider).status;
  bool get isAuthenticated => container.read(authProvider).isAuthenticated;

  void dispose() => container.dispose();
}

/// THE WOULD-BE BUG, written out so it can be falsified.
///
/// This is what a consuming app actually does with an authentication-layer
/// refusal — `AuthNotifier.restoreSession`'s `on AuthError` arm
/// (auth_provider.dart:410-413) and AODex's Dio 401 interceptor
/// (auth_service.dart:139-147) both reduce to exactly this. `AoidError` is in
/// the family on purpose: an AOID auth-layer refusal SHOULD sign the user out.
///
/// The whole of SDK-07's safety is that a tenant denial is NOT in this family.
Future<void> _appSignOutOnAuthFailure(
  Object error,
  _LiveSession session,
) async {
  if (error is AuthError || error is AoidError) {
    await session.storage.clear();
    await session.container.read(authProvider.notifier).logout();
  }
}

void main() {
  late _FakeAoidTokenEndpoint fake;

  setUp(() {
    fake = _FakeAoidTokenEndpoint(memberOf: {homeTenantSlug, tenantBSlug});
  });

  group('fixture non-vacuity', () {
    test(
      'F1 the fake serves the refresh grant and ROTATES the token',
      () async {
        final res = await fake.client.post(
          Uri.parse('$_issuer/oauth/token'),
          headers: const {'content-type': 'application/x-www-form-urlencoded'},
          body: {
            'grant_type': 'refresh_token',
            'refresh_token': 'refresh-token-0001',
            'client_id': _clientId,
          },
        );
        expect(res.statusCode, 200);
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        expect(body['refresh_token'], isNot('refresh-token-0001'));
        expect(fake.liveRefreshToken, body['refresh_token']);
      },
    );

    test('F2 the membership gate is NON-CONSUMING: a denied switch leaves the '
        'presented refresh token LIVE', () async {
      final denied = await fake.client.post(
        Uri.parse('$_issuer/oauth/token'),
        headers: const {'content-type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': 'refresh-token-0001',
          'client_id': _clientId,
          'active_tenant': _outsiderSlug,
        },
      );
      expect(denied.statusCode, 400);
      expect(fake.liveRefreshToken, 'refresh-token-0001');

      final after = await fake.client.post(
        Uri.parse('$_issuer/oauth/token'),
        headers: const {'content-type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': 'refresh-token-0001',
          'client_id': _clientId,
        },
      );
      expect(after.statusCode, 200);
    });

    test(
      'F3 a denied switch and a bad refresh token are BYTE-IDENTICAL — status, '
      'every header, and the raw body',
      () async {
        final denied = await fake.client.post(
          Uri.parse('$_issuer/oauth/token'),
          headers: const {'content-type': 'application/x-www-form-urlencoded'},
          body: {
            'grant_type': 'refresh_token',
            'refresh_token': 'refresh-token-0001',
            'client_id': _clientId,
            'active_tenant': _outsiderSlug,
          },
        );
        final badToken = await fake.client.post(
          Uri.parse('$_issuer/oauth/token'),
          headers: const {'content-type': 'application/x-www-form-urlencoded'},
          body: {
            'grant_type': 'refresh_token',
            'refresh_token': 'a-token-that-was-never-issued',
            'client_id': _clientId,
          },
        );
        expect(denied.statusCode, badToken.statusCode);
        expect(denied.headers, badToken.headers);
        expect(denied.body, badToken.body);
      },
    );
  });

  group('the refresh grant carries active_tenant as a FORM FIELD', () {
    test('item 1 — refresh(activeTenant:) sends active_tenant in the form body '
        'with the slug value', () async {
      await _clientFor(fake).refresh(
        refreshToken: 'refresh-token-0001',
        activeTenant: const AoidActiveTenantSlug(tenantBSlug),
      );
      expect(fake.requests, hasLength(1));
      final sent = fake.requests.single;
      expect(sent.fields['grant_type'], 'refresh_token');
      expect(sent.fields['refresh_token'], 'refresh-token-0001');
      expect(sent.fields['client_id'], _clientId);
      expect(
        sent.fields['active_tenant'],
        tenantBSlug,
        reason:
            'active_tenant must be a FORM FIELD (aoid '
            'the token endpoint) — that is what keeps the '
            'switch a CORS simple request with no preflight',
      );
      // The raw body, not merely the parsed map: a header would not appear
      // here at all.
      expect(sent.rawBody, contains('active_tenant=$tenantBSlug'));
    });

    test(
      'item 1b — an ordinary refresh omits active_tenant entirely rather than '
      'sending an empty value',
      () async {
        await _clientFor(fake).refresh(refreshToken: 'refresh-token-0001');
        expect(
          fake.requests.single.fields.containsKey('active_tenant'),
          isFalse,
        );
      },
    );

    test('item 2 — NO custom header: the outgoing header map carries only the '
        'content type', () async {
      await _clientFor(fake).refresh(
        refreshToken: 'refresh-token-0001',
        activeTenant: const AoidActiveTenantSlug(tenantBSlug),
      );
      final headers = fake.requests.single.headers;
      expect(
        headers.keys.map((k) => k.toLowerCase()).toSet(),
        {'content-type'},
        reason:
            'ANY header beyond a CORS-safelisted content type provokes a '
            'preflight. An X-Active-Tenant header would break every browser '
            'caller.',
      );
      expect(
        headers['content-type']!.split(';').first.trim(),
        'application/x-www-form-urlencoded',
      );
    });
  });

  group('the switch itself', () {
    test(
      'item 10 POSITIVE CONTROL — a switch to a tenant the user IS a member of '
      'succeeds, and the NEW ACCESS token carries the requested slug',
      () async {
        final response = await _clientFor(fake).refresh(
          refreshToken: 'refresh-token-0001',
          activeTenant: const AoidActiveTenantSlug(tenantBSlug),
        );

        expect(response.accessToken, isNotEmpty);
        expect(response.refreshToken, isNotNull);
        expect(
          response.refreshToken,
          isNot('refresh-token-0001'),
          reason: 'a successful grant ROTATES the refresh token',
        );

        // The only place the client learns the switch actually took effect.
        final claims = AoidAccessClaims.decodeUnverified(response.accessToken);
        expect(claims.activeTenant.slug, tenantBSlug);

        //...and the id_token deliberately does NOT follow the switch, so a
        // client that verified by decoding it would be wrong. Pinned here so
        // nobody "simplifies" the verification onto the id_token later.
        expect(response.idToken, isNotNull);
        expect(
          AoidIdClaims.decodeUnverified(response.idToken!).homeTenant.uuid,
          homeTenantUuid,
        );
      },
    );
  });

  group('A DENIED SWITCH IS NOT A SIGN-OUT', () {
    late _LiveSession session;

    setUp(() async {
      session = await _LiveSession.start();
    });

    tearDown(() => session.dispose());

    test(
      'item 9c POSITIVE CONTROL for the handler — a real AuthError DOES clear '
      'tokens and sign the user out',
      () async {
        expect(session.status, AuthStatus.authenticated);
        await _appSignOutOnAuthFailure(AuthError('token expired'), session);
        expect(
          session.status,
          AuthStatus.unauthenticated,
          reason: 'if this does not sign out, item 9 proves nothing',
        );
        expect(session.storage.values, isEmpty);
      },
    );

    test(
      'item 9c2 POSITIVE CONTROL — an AoidError (an AOID authentication-layer '
      'refusal) also signs the user out, which is CORRECT',
      () async {
        await _appSignOutOnAuthFailure(
          const AoidError(AoidErrorCode.invalidSession),
          session,
        );
        expect(session.status, AuthStatus.unauthenticated);
        expect(session.storage.values, isEmpty);
      },
    );

    test(
      'item 9 — a switch to a NON-MEMBER tenant yields AoidTenantDenied, and '
      'the session survives it: status UNCHANGED, tokens UNTOUCHED, still '
      'authenticated',
      () async {
        expect(session.status, AuthStatus.authenticated);
        final before = Map<String, String>.from(session.storage.values);

        Object? thrown;
        try {
          await _clientFor(fake).refresh(
            refreshToken: _seedRefreshToken,
            activeTenant: const AoidActiveTenantSlug(_outsiderSlug),
          );
        } catch (e) {
          thrown = e;
        }

        expect(
          thrown,
          isA<AoidTenantDenied>(),
          reason: 'a denial is a PERMISSION answer, not a SESSION answer',
        );
        // Structural, not nominal: the type must not be in the family the
        // app's sign-out handler keys on.
        expect(thrown, isNot(isA<AuthError>()));
        expect(thrown, isNot(isA<AoidError>()));

        //...and now the part that actually matters. Run the SAME handler that
        // item 9c proved signs people out.
        await _appSignOutOnAuthFailure(thrown!, session);

        expect(
          session.status,
          AuthStatus.authenticated,
          reason:
              'asking about a workspace you are not in must not sign you '
              'out (the token service)',
        );
        expect(session.isAuthenticated, isTrue);
        expect(
          session.storage.values,
          before,
          reason: 'no token may be cleared by a denial',
        );
      },
    );

    test(
      'item 11 — a denied switch does not BURN the refresh token: the same '
      'token succeeds on an ordinary refresh immediately afterwards',
      () async {
        await expectLater(
          _clientFor(fake).refresh(
            refreshToken: _seedRefreshToken,
            activeTenant: const AoidActiveTenantSlug(_outsiderSlug),
          ),
          throwsA(isA<AoidTenantDenied>()),
        );

        // the token service does a NON-CONSUMING read precisely so a bad
        // target does not burn the token. The client must not undo that by
        // clearing storage on the error path.
        expect(await session.storage.readRefreshToken(), _seedRefreshToken);

        final recovered = await _clientFor(
          fake,
        ).refresh(refreshToken: _seedRefreshToken);
        expect(recovered.accessToken, isNotEmpty);
        expect(
          AoidAccessClaims.decodeUnverified(
            recovered.accessToken,
          ).activeTenant.slug,
          homeTenantSlug,
          reason: 'GID-14: with no active selection tnt is the HOME SLUG',
        );
      },
    );

    test(
      'item 12 — the denial carries NO reason detail: no slug, no membership '
      'verdict, and nothing the server said',
      () async {
        Object? thrown;
        try {
          await _clientFor(fake).refresh(
            refreshToken: _seedRefreshToken,
            activeTenant: const AoidActiveTenantSlug(_outsiderSlug),
          );
        } catch (e) {
          thrown = e;
        }
        final denial = thrown! as AoidTenantDenied;
        final rendered = '$denial ${denial.message}';

        // The target slug would tell an attacker WHICH probe failed.
        expect(rendered, isNot(contains(_outsiderSlug)));
        // A membership verdict is exactly the oracle service.go withholds.
        expect(rendered.toLowerCase(), isNot(contains('member')));
        expect(rendered.toLowerCase(), isNot(contains('not a member')));
        // The server's own strings must never be reflected.
        expect(rendered, isNot(contains('invalid_grant')));
        expect(rendered, isNot(contains('invalid or expired refresh token')));
        //...and it must still say something a human can read.
        expect(denial.message, isNotEmpty);
      },
    );

    test('item 12b — every AoidTenantDenied is indistinguishable from every '
        'other, so the type cannot become an oracle by accident', () async {
      expect(const AoidTenantDenied(), const AoidTenantDenied());
      expect(
        const AoidTenantDenied().toString(),
        const AoidTenantDenied().toString(),
      );
    });
  });

  group('the retry DECISION — riverpod-3 migration checklist item 4', () {
    // riverpod 3 retries a failed provider TEN times over 38.2 seconds and
    // declines only for `ProviderException` and `Error`, so every ordinary
    // `Exception` is retried. Item 4b then makes the `error:` arm of
    // `AsyncValue.when()` UNREACHABLE for that whole window, because a pending
    // retry emits an AsyncLoading that also carries the error.
    //
    // AoidTenantDenied is an `Exception` — deliberately, see its doc comment —
    // so a consumer that surfaces the switch through a provider MUST pass this
    // policy as `retry:`. Ten silent re-probes of a workspace the user is not
    // in is also ten `auth.active_tenant.denied` audit rows per tap.
    test(
      'item 13 — a denial is NEVER retried: it is a refusal, not a blip',
      () {
        expect(aoidTenantSwitchRetry(0, const AoidTenantDenied()), isNull);
        expect(aoidTenantSwitchRetry(5, const AoidTenantDenied()), isNull);
      },
    );

    test('item 13b — an AOID authentication refusal is not retried either', () {
      expect(
        aoidTenantSwitchRetry(0, const AoidError(AoidErrorCode.invalidSession)),
        isNull,
      );
    });

    test('item 13c — a genuine transport blip IS retried, but boundedly: 3 '
        'attempts, not riverpod\'s 10 over 38.2s', () {
      const blip = AoidTransportError(AoidTransportFailureKind.unavailable);
      expect(aoidTenantSwitchRetry(0, blip), isNotNull);
      expect(aoidTenantSwitchRetry(1, blip), isNotNull);
      expect(aoidTenantSwitchRetry(2, blip), isNotNull);
      expect(
        aoidTenantSwitchRetry(3, blip),
        isNull,
        reason: 'bounded — the user must eventually see an error',
      );
      // Monotonic backoff, and the whole window is well under riverpod's.
      final total = [0, 1, 2]
          .map((i) => aoidTenantSwitchRetry(i, blip)!.inMilliseconds)
          .reduce((a, b) => a + b);
      expect(total, lessThan(5000));
    });
  });
}
