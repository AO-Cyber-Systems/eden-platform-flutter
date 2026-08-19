import 'package:flutter_test/flutter_test.dart';

import 'package:eden_platform_flutter/eden_platform.dart';

/// Delegated authentication WITHOUT a browser hop (PLAT-02, #22).
///
/// The application renders its own login form and exchanges credentials with
/// the issuer directly. The multi-step ceremony already existed as
/// [AoidNativeFlow]; what did not exist was any way to select it through the
/// [AuthStrategy] interface, so an app wanting it had to drive the flow by
/// hand and reimplement the state mapping.
///
/// The interesting constraint: [AoidNativeFlow] keeps its `auth_session`
/// handle PRIVATE and rotates it on every step, deliberately, so that no
/// caller can hold a stale copy. The strategy therefore cannot hand that
/// handle out as [FactorRequired.continuationToken] — it issues its own opaque
/// token and keeps the flow. That is the point of these tests.

class _FakeSink implements AoidCodeSink {
  _FakeSink({this.session, this.error});
  final AoidSession? session;
  final Object? error;
  String? submittedCode;
  String? submittedVerifier;

  @override
  Future<AoidSession> submit({
    required String code,
    required String codeVerifier,
    String? redirectUri,
  }) async {
    submittedCode = code;
    submittedVerifier = codeVerifier;
    if (error != null) throw error!;
    return session!;
  }
}

void main() {
  group('NativeDelegatedAuthStrategy', () {
    test('a password step that needs a second factor yields FactorRequired', () async {
      final s = NativeDelegatedAuthStrategy(
        flow: FakeNativeCeremony(
          afterPassword: const AoidFlowAwaitingFactor(
            next: 'mfa',
            availableMethods: ['totp', 'backup_code'],
          ),
        ),
        codeSink: _FakeSink(),
      );

      final r = await s.initiateLogin({'email': 'a@b.c', 'password': 'pw'});

      expect(r, isA<FactorRequired>());
      final f = r as FactorRequired;
      expect(f.next, 'mfa');
      expect(f.availableMethods, ['totp', 'backup_code']);
      expect(
        f.continuationToken,
        isNotEmpty,
        reason: 'the UI passes this back to completeLogin; an empty handle '
            'makes the second step unaddressable',
      );
    });

    test('the continuation token is the strategy\'s own, never the flow handle', () async {
      final flow = FakeNativeCeremony(
        afterPassword: const AoidFlowAwaitingFactor(next: 'mfa'),
      );
      final s = NativeDelegatedAuthStrategy(flow: flow, codeSink: _FakeSink());

      final r = await s.initiateLogin({'email': 'a@b.c', 'password': 'pw'});

      expect(
        (r as FactorRequired).continuationToken,
        isNot(equals(flow.lastIssuedHandle)),
        reason: 'the flow rotates and consumes its handle on every step, so a '
            'caller holding a copy would present a dead value — the strategy '
            'must issue an opaque token of its own',
      );
    });

    test('a stale continuation token is refused', () async {
      final s = NativeDelegatedAuthStrategy(
        flow: FakeNativeCeremony(afterPassword: const AoidFlowAwaitingFactor(next: 'mfa')),
        codeSink: _FakeSink(),
      );
      await s.initiateLogin({'email': 'a@b.c', 'password': 'pw'});

      final r = await s.completeLogin('not-the-token', const {'totp': '123456'});

      expect(r, isA<Failed>());
    });

    test('a redirect-required factor is surfaced as an outcome, not an error', () async {
      final s = NativeDelegatedAuthStrategy(
        flow: FakeNativeCeremony(
          afterPassword: AoidFlowRedirectRequired(
            RedirectRequired(Uri.parse('https://idp.example/authorize?x=1')),
          ),
        ),
        codeSink: _FakeSink(),
      );

      final r = await s.initiateLogin({'email': 'a@b.c', 'password': 'pw'});

      expect(
        r,
        isA<RedirectRequired>(),
        reason: 'a factor that cannot complete in-app is a normal outcome; '
            'mapping it onto Failed shows "login failed" to a user whose '
            'credentials are fine',
      );
      expect((r as RedirectRequired).authorizationUrl.host, 'idp.example');
    });

    test('a completed ceremony exchanges the code and authenticates', () async {
      final sink = _FakeSink(session: AoidSession.deviceKeychain(accessToken: 'at-9', refreshToken: 'rt-9'));
      final s = NativeDelegatedAuthStrategy(
        flow: FakeNativeCeremony(afterPassword: const AoidFlowComplete('code-abc')),
        codeSink: sink,
      );

      final r = await s.initiateLogin({'email': 'a@b.c', 'password': 'pw'});

      expect(r, isA<Authenticated>());
      expect((r as Authenticated).session.accessToken, 'at-9');
      expect(sink.submittedCode, 'code-abc');
      expect(
        sink.submittedVerifier,
        isNotEmpty,
        reason: 'the verifier proves this client began the ceremony; omitting '
            'it makes the code redeemable by anyone who intercepts it',
      );
    });

    test('a failed exchange is Failed, not a thrown error', () async {
      final s = NativeDelegatedAuthStrategy(
        flow: FakeNativeCeremony(afterPassword: const AoidFlowComplete('code-abc')),
        codeSink: _FakeSink(error: Exception('backend down')),
      );

      expect(await s.initiateLogin({'email': 'a@b.c', 'password': 'pw'}), isA<Failed>());
    });

    test('a dead ceremony asks for a restart rather than looping', () async {
      final s = NativeDelegatedAuthStrategy(
        flow: FakeNativeCeremony(afterPassword: const AoidFlowRestartRequired()),
        codeSink: _FakeSink(),
      );

      final r = await s.initiateLogin({'email': 'a@b.c', 'password': 'pw'});

      expect(r, isA<Failed>());
      expect((r as Failed).reason.toLowerCase(), contains('again'));
    });

    test('an EMPTY password fails without starting a ceremony', () async {
      // Distinct from the absent-password case above: a form that submits ''
      // for an untouched field is the common shape, and null-safety does not
      // catch it. Found by mutation testing — dropping the isEmpty half of the
      // guard killed no test until this one existed.
      final flow = FakeNativeCeremony(afterPassword: const AoidFlowComplete('c'));
      final s = NativeDelegatedAuthStrategy(flow: flow, codeSink: _FakeSink());

      final r = await s.initiateLogin(const {'email': 'a@b.c', 'password': ''});

      expect(r, isA<Failed>());
      expect(flow.beginCalls, 0);
    });

    test('missing credentials fail without starting a ceremony', () async {
      final flow = FakeNativeCeremony(afterPassword: const AoidFlowComplete('c'));
      final s = NativeDelegatedAuthStrategy(flow: flow, codeSink: _FakeSink());

      final r = await s.initiateLogin(const {'email': 'a@b.c'});

      expect(r, isA<Failed>());
      expect(
        flow.beginCalls,
        0,
        reason: 'starting a ceremony burns a durable attempt against the '
            "issuer's per-handle cap",
      );
    });
  });
}

/// A ceremony whose state the test controls directly.
///
/// Implements [NativeCeremony] rather than subclassing [AoidNativeFlow]: the
/// flow's handle is private by design, and a fake that reached into it would
/// be testing something the strategy cannot see anyway.
class FakeNativeCeremony implements NativeCeremony {
  FakeNativeCeremony({required this.afterPassword, this.afterFactor});

  /// State to report once the password step has been submitted.
  final AoidFlowState afterPassword;

  /// State to report after a second factor. Defaults to [afterPassword].
  final AoidFlowState? afterFactor;

  int beginCalls = 0;

  /// The handle a real ceremony would be holding. Exposed ONLY so a test can
  /// assert the strategy does not hand it out.
  String? lastIssuedHandle;

  AoidFlowState _state = const AoidFlowIdle();

  @override
  AoidFlowState get state => _state;

  @override
  Future<void> begin({required String codeChallenge, String? loginHint}) async {
    beginCalls++;
    lastIssuedHandle = 'server-handle-1';
    _state = const AoidFlowAwaitingFactor(next: 'password');
  }

  @override
  Future<void> submitPassword({required String email, required String password}) async {
    lastIssuedHandle = 'server-handle-2';
    _state = afterPassword;
  }

  @override
  Future<void> submitOtp(String otp) async {
    lastIssuedHandle = 'server-handle-3';
    _state = afterFactor ?? afterPassword;
  }

  @override
  Future<void> submitWebAuthn(String responseJson, {String method = 'webauthn'}) async {
    lastIssuedHandle = 'server-handle-3';
    _state = afterFactor ?? afterPassword;
  }
}
