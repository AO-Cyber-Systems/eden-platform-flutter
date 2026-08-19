// the test list items 5-12 — the code-only browser hop.
//
// Item 6 is written first and deliberately: it is the D6 invariant for this
// new callback handler. The SSO removal's repo-wide gate covers the SOURCE of this file
// textually; item 6 covers the BEHAVIOUR.

import 'dart:async';
import 'dart:io';

import 'package:eden_platform_flutter/eden_platform.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart'
    show FlutterWebAuth2Options;

import '../source_utils.dart';

/// Records every authorize invocation and hands back a caller-controlled
/// future, so a test can hold the ceremony open while the clock advances.
class _SpyAuthorize {
  final List<String> urls = <String>[];
  final List<String> schemes = <String>[];
  final List<FlutterWebAuth2Options> optionsSeen = <FlutterWebAuth2Options>[];
  Completer<String> completer = Completer<String>();
  int calls = 0;

  Future<String> call({
    required String url,
    required String callbackUrlScheme,
    required FlutterWebAuth2Options options,
  }) {
    calls++;
    urls.add(url);
    schemes.add(callbackUrlScheme);
    optionsSeen.add(options);
    return completer.future;
  }
}

/// A [Timer] the test fires by hand — the injected clock item 8 needs.
class _FakeTimer implements Timer {
  _FakeTimer(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;
  bool cancelled = false;
  int fires = 0;

  void fire() {
    if (cancelled) return;
    fires++;
    callback();
  }

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => fires;
}

class _FakeClock {
  final List<_FakeTimer> timers = <_FakeTimer>[];

  Timer call(Duration d, void Function() cb) {
    final t = _FakeTimer(d, cb);
    timers.add(t);
    return t;
  }

  _FakeTimer get only {
    expect(timers, hasLength(1), reason: 'expected exactly one watchdog timer');
    return timers.single;
  }
}

const _kVerifier = 'verifier-0123456789012345678901234567890123456789012345';
const _kState = 'state-abc';

PkcePair _fixedPkce() => PkcePair(
  codeVerifier: _kVerifier,
  codeChallenge: PkceGenerator.codeChallengeFor(_kVerifier),
  state: _kState,
  nonce: 'nonce-abc',
);

({AoidRedirectFlow flow, _SpyAuthorize spy, Map<String, String> storage})
_build({_FakeClock? clock, bool isWeb = false, Map<String, String>? storage}) {
  final spy = _SpyAuthorize();
  final backing = storage ?? <String, String>{};
  final flow = AoidRedirectFlow(
    endpoints: AoidEndpoints.parse('https://auth.aocyber.localhost'),
    clientId: 'eden-biz-mobile',
    redirectUri: 'edenbiz://auth',
    options: AoidRedirectOptions(callbackScheme: 'edenbiz'),
    authorize: spy.call,
    stash: AoidMapVerifierStash(backing),
    isWeb: isWeb,
    generatePkce: _fixedPkce,
    createTimer: clock?.call,
  );
  return (flow: flow, spy: spy, storage: backing);
}

void main() {
  group('item 5: a successful hop returns the authorization CODE', () {
    test('the code is parsed out of the callback URL', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.complete('edenbiz://auth?code=THE_CODE&state=$_kState');

      final outcome = await future;
      expect(outcome, isA<AoidRedirectCode>());
      expect((outcome as AoidRedirectCode).code, 'THE_CODE');
    });

    test('it carries the PKCE verifier the exchange will need', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.complete('edenbiz://auth?code=THE_CODE&state=$_kState');

      final outcome = await future as AoidRedirectCode;
      expect(outcome.codeVerifier, _kVerifier);
    });

    test('toString() redacts the code and the verifier', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.complete('edenbiz://auth?code=THE_CODE&state=$_kState');

      final text = (await future).toString();
      expect(text, isNot(contains('THE_CODE')));
      expect(text, isNot(contains(_kVerifier)));
    });
  });

  group('item 6: a callback carrying a token is REJECTED, not used', () {
    test('an access token in the query string is refused', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.complete(
        'edenbiz://auth?code=THE_CODE&state=$_kState'
        '&${'access'}_token=leaked-value',
      );

      final outcome = await future;
      expect(
        outcome,
        isA<AoidRedirectRejected>().having(
          (r) => r.reason,
          'reason',
          AoidRedirectRejection.tokenInCallback,
        ),
        reason:
            'D6: a transitional server appending a token to the callback must '
            'be REFUSED, not opportunistically used',
      );
    });

    test('a refresh token in the query string is refused', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.complete(
        'edenbiz://auth?code=THE_CODE&state=$_kState'
        '&${'refresh'}_token=leaked-value',
      );

      expect(await future, isA<AoidRedirectRejected>());
    });

    test('a token in the URL FRAGMENT is refused too', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.complete(
        'edenbiz://auth?state=$_kState#${'access'}_token=leaked-value',
      );

      expect(
        await future,
        isA<AoidRedirectRejected>().having(
          (r) => r.reason,
          'reason',
          AoidRedirectRejection.tokenInCallback,
        ),
        reason:
            'the implicit flow puts tokens in the fragment; refusing only the '
            'query string would leave the older leak wide open',
      );
    });

    test('the rejection does NOT surface the token value anywhere', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.complete(
        'edenbiz://auth?code=THE_CODE&state=$_kState'
        '&${'access'}_token=leaked-value',
      );

      expect((await future).toString(), isNot(contains('leaked-value')));
    });

    test('a token-bearing callback leaves NO verifier behind', () async {
      final b = _build(isWeb: true);
      final future = b.flow.start();
      b.spy.completer.complete(
        'edenbiz://auth?code=THE_CODE&state=$_kState'
        '&${'access'}_token=leaked-value',
      );

      await future;
      expect(b.storage, isEmpty);
    });
  });

  group('item 7: a state mismatch aborts BEFORE any exchange', () {
    test('a mismatched state is rejected as stateMismatch', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.complete(
        'edenbiz://auth?code=THE_CODE&state=attacker-supplied',
      );

      expect(
        await future,
        isA<AoidRedirectRejected>().having(
          (r) => r.reason,
          'reason',
          AoidRedirectRejection.stateMismatch,
        ),
      );
    });

    test('no code is handed back, so no exchange is possible', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.complete(
        'edenbiz://auth?code=THE_CODE&state=attacker-supplied',
      );

      final outcome = await future;
      expect(
        outcome,
        isNot(isA<AoidRedirectCode>()),
        reason:
            'the code is the ONLY thing a caller could exchange; withholding '
            'it is what "aborts before any exchange" means for this type',
      );
      expect(outcome.toString(), isNot(contains('THE_CODE')));
    });

    test('and the verifier is dropped, so an exchange cannot be '
        'reconstructed', () async {
      final b = _build(isWeb: true);
      final future = b.flow.start();
      b.spy.completer.complete(
        'edenbiz://auth?code=THE_CODE&state=attacker-supplied',
      );

      await future;
      expect(b.storage, isEmpty);
    });

    test('a missing state is a mismatch too', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.complete('edenbiz://auth?code=THE_CODE');

      expect(
        await future,
        isA<AoidRedirectRejected>().having(
          (r) => r.reason,
          'reason',
          AoidRedirectRejection.stateMismatch,
        ),
      );
    });
  });

  group('item 8: the watchdog fires at ~20s, not 300', () {
    test('it is armed for the configured watchdog, not the package '
        'timeout', () {
      final clock = _FakeClock();
      final b = _build(clock: clock);
      b.flow.start(onPossiblyBlocked: (_) {});

      expect(clock.only.duration, const Duration(seconds: 20));
      expect(
        clock.only.duration.inSeconds,
        lessThan(const FlutterWebAuth2Options().timeout),
        reason:
            'the package default is a 300-second silent hang '
            '(options.dart:66); beating it is the entire point',
      );
    });

    test('it is armed BEFORE the browser is launched', () {
      final clock = _FakeClock();
      final spy = _SpyAuthorize();
      Duration? armedAt;
      final flow = AoidRedirectFlow(
        endpoints: AoidEndpoints.parse('https://auth.aocyber.localhost'),
        clientId: 'c',
        redirectUri: 'edenbiz://auth',
        options: AoidRedirectOptions(callbackScheme: 'edenbiz'),
        authorize:
            ({required url, required callbackUrlScheme, required options}) {
              armedAt = clock.timers.isEmpty
                  ? null
                  : clock.timers.single.duration;
              return spy.call(
                url: url,
                callbackUrlScheme: callbackUrlScheme,
                options: options,
              );
            },
        generatePkce: _fixedPkce,
        createTimer: clock.call,
      );
      flow.start(onPossiblyBlocked: (_) {});

      expect(
        armedAt,
        isNotNull,
        reason:
            'a watchdog armed AFTER the launch measures from the wrong '
            'instant and never arms at all if the launch throws',
      );
    });

    test('nothing is surfaced before it fires', () async {
      final clock = _FakeClock();
      final b = _build(clock: clock);
      final hints = <AoidRedirectBlockedHint>[];
      var settled = false;
      unawaited(
        b.flow.start(onPossiblyBlocked: hints.add).then((_) {
          settled = true;
        }),
      );
      await pumpEventQueue();

      expect(hints, isEmpty);
      expect(settled, isFalse);
    });

    test('when it fires it advises WITHOUT cancelling the live '
        'ceremony', () async {
      final clock = _FakeClock();
      final b = _build(clock: clock);
      final hints = <AoidRedirectBlockedHint>[];
      AoidRedirectOutcome? outcome;
      unawaited(
        b.flow.start(onPossiblyBlocked: hints.add).then((o) => outcome = o),
      );

      clock.only.fire();
      await pumpEventQueue();

      expect(hints, hasLength(1), reason: 'the advice was surfaced');
      expect(
        outcome,
        isNull,
        reason:
            'THE OTHER HALF: a watchdog that aborts a slow-but-live login is '
            'worse than the hang it replaces. The future must still be open',
      );

      // The slow-but-live ceremony completes late and still wins.
      b.spy.completer.complete('edenbiz://auth?code=THE_CODE&state=$_kState');
      await pumpEventQueue();
      expect(outcome, isA<AoidRedirectCode>());
      expect((outcome! as AoidRedirectCode).code, 'THE_CODE');
    });

    test('the hint offers a same-tab fallback and claims no certainty', () {
      final clock = _FakeClock();
      final b = _build(clock: clock);
      final hints = <AoidRedirectBlockedHint>[];
      b.flow.start(onPossiblyBlocked: hints.add);
      clock.only.fire();

      final hint = hints.single;
      expect(hint.message.toLowerCase(), contains('may have blocked'));
      expect(hint.authorizeUrl.toString(), contains('/oauth/authorize'));
      expect(
        hint.authorizeUrl.queryParameters['code_challenge_method'],
        'S256',
      );
      expect(hint.toString(), isNot(contains('code_challenge')));
    });

    test('the timer is cancelled when the ceremony ends — no leak', () async {
      final clock = _FakeClock();
      final b = _build(clock: clock);
      final future = b.flow.start(onPossiblyBlocked: (_) {});
      b.spy.completer.complete('edenbiz://auth?code=THE_CODE&state=$_kState');
      await future;

      expect(clock.only.cancelled, isTrue);
    });

    test('no watchdog is armed when no listener asked for one', () {
      final clock = _FakeClock();
      final b = _build(clock: clock);
      b.flow.start();

      expect(clock.timers, isEmpty);
    });
  });

  group('item 9: the verifier survives a full-page reload', () {
    test('a fresh flow over the same storage restores the original '
        'verifier', () async {
      // The tab as it was before the redirect.
      final storage = <String, String>{};
      final before = _build(isWeb: true, storage: storage);
      final url = before.flow.beginSameTabFallback(_fixedPkce());

      expect(url.toString(), contains('/oauth/authorize'));
      expect(
        storage.values,
        contains(_kVerifier),
        reason: 'stashed BEFORE the navigation, or it is gone on reload',
      );

      // ---- the page unloads; every Dart object above is destroyed ----
      final after = _build(isWeb: true, storage: storage);
      expect(
        after.flow.hasStashedVerifier,
        isTrue,
        reason: 'the new instance can see what the old one left',
      );

      final outcome = after.flow.resume(
        'edenbiz://auth?code=THE_CODE&state=$_kState',
      );

      expect(outcome, isA<AoidRedirectCode>());
      expect(
        (outcome as AoidRedirectCode).codeVerifier,
        _kVerifier,
        reason:
            'the ORIGINAL verifier — the exchange fails with invalid_grant '
            'against any other value',
      );
      expect(outcome.code, 'THE_CODE');
    });

    test('WITHOUT the stash the same reload loses the verifier — the '
        'defect this exists to prevent', () {
      // The in-memory field AoidOidcAuthStrategy uses, simulated: a fresh
      // instance with nothing persisted.
      final after = _build(isWeb: true);

      expect(after.flow.hasStashedVerifier, isFalse);
      final outcome = after.flow.resume(
        'edenbiz://auth?code=THE_CODE&state=$_kState',
      );

      expect(
        outcome,
        isA<AoidRedirectRejected>().having(
          (r) => r.reason,
          'reason',
          AoidRedirectRejection.verifierLost,
        ),
        reason:
            'verifier loss must be NAMED, not surfaced as an opaque '
            'invalid_grant from the token endpoint three calls later',
      );
    });

    test('a same-tab return with a mismatched state is still refused', () {
      final storage = <String, String>{};
      _build(
        isWeb: true,
        storage: storage,
      ).flow.beginSameTabFallback(_fixedPkce());
      final after = _build(isWeb: true, storage: storage);

      expect(
        after.flow.resume(
          'edenbiz://auth?code=THE_CODE&state=attacker',
          expectedState: _kState,
        ),
        isA<AoidRedirectRejected>().having(
          (r) => r.reason,
          'reason',
          AoidRedirectRejection.stateMismatch,
        ),
      );
    });

    test('a same-tab return carrying a token is still refused', () {
      final storage = <String, String>{};
      _build(
        isWeb: true,
        storage: storage,
      ).flow.beginSameTabFallback(_fixedPkce());
      final after = _build(isWeb: true, storage: storage);

      expect(
        after.flow.resume(
          'edenbiz://auth?code=THE_CODE&${'access'}_token=leaked',
        ),
        isA<AoidRedirectRejected>().having(
          (r) => r.reason,
          'reason',
          AoidRedirectRejection.tokenInCallback,
        ),
      );
    });

    test('on NATIVE nothing is stashed — the process survives the hop', () {
      final b = _build(isWeb: false);
      b.flow.start();

      expect(
        b.storage,
        isEmpty,
        reason:
            'a stash on native would put PKCE material at rest for no '
            'benefit; the isolate is still there when the callback arrives',
      );
    });
  });

  group('item 10: the stash is bounded and cleared', () {
    test('it holds exactly ONE key, and that key is the verifier', () {
      final storage = <String, String>{};
      final b = _build(isWeb: true, storage: storage);
      b.flow.start();

      expect(storage.keys, hasLength(1));
      expect(storage.keys.single, AoidVerifierStash.storageKey);
      expect(storage.values.single, _kVerifier);
    });

    test('nothing else from the ceremony is persisted', () {
      final storage = <String, String>{};
      final pair = _fixedPkce();
      _build(isWeb: true, storage: storage).flow.start();

      final blob = storage.entries.map((e) => '${e.key}=${e.value}').join('|');
      expect(blob, isNot(contains(pair.state)));
      expect(blob, isNot(contains(pair.nonce)));
      expect(blob, isNot(contains(pair.codeChallenge)));
    });

    test('it is cleared on SUCCESS', () async {
      final storage = <String, String>{};
      final b = _build(isWeb: true, storage: storage);
      final future = b.flow.start();
      b.spy.completer.complete('edenbiz://auth?code=THE_CODE&state=$_kState');
      await future;

      expect(storage, isEmpty);
    });

    test('it is cleared on CANCELLATION too', () async {
      final storage = <String, String>{};
      final b = _build(isWeb: true, storage: storage);
      final future = b.flow.start();
      b.spy.completer.completeError(
        PlatformException(code: 'CANCELED', message: 'User canceled'),
      );
      await future;

      expect(
        storage,
        isEmpty,
        reason: 'an abandoned ceremony must not leave PKCE material behind',
      );
    });

    test('it is cleared after a same-tab resume', () {
      final storage = <String, String>{};
      _build(
        isWeb: true,
        storage: storage,
      ).flow.beginSameTabFallback(_fixedPkce());
      final after = _build(isWeb: true, storage: storage);
      after.flow.resume('edenbiz://auth?code=THE_CODE&state=$_kState');

      expect(storage, isEmpty);
    });

    test('but NOT cleared while the same-tab hop is in flight', () {
      final storage = <String, String>{};
      _build(
        isWeb: true,
        storage: storage,
      ).flow.beginSameTabFallback(_fixedPkce());

      expect(
        storage,
        isNotEmpty,
        reason: 'surviving the page unload is the entire point of the stash',
      );
    });
  });

  group('item 11: the authorize call gets the configured scheme and URL', () {
    test('scheme, URL and PKCE parameters all arrive', () {
      final b = _build();
      b.flow.start();

      expect(b.spy.schemes.single, 'edenbiz');
      final url = Uri.parse(b.spy.urls.single);
      expect(url.origin, 'https://auth.aocyber.localhost');
      expect(url.path, '/oauth/authorize');
      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters['client_id'], 'eden-biz-mobile');
      expect(url.queryParameters['redirect_uri'], 'edenbiz://auth');
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(
        url.queryParameters['code_challenge'],
        PkceGenerator.codeChallengeFor(_kVerifier),
      );
      expect(url.queryParameters['state'], _kState);
    });

    test('the authorize URL never carries the verifier itself', () {
      final b = _build();
      b.flow.start();

      expect(b.spy.urls.single, isNot(contains(_kVerifier)));
    });

    // ITEM 2, at the level that actually matters: the options object that
    // REACHED the call, not the field that produced it.
    test('item 2 (call level): useWebview is false in the options that '
        'REACHED the authorize call', () {
      final b = _build();
      b.flow.start();

      expect(
        b.spy.optionsSeen.single.useWebview,
        isFalse,
        reason:
            'a field that is set but never threaded through is the common '
            'failure; this is the assertion that catches it',
      );
    });

    test('item 3 (call level): preferEphemeral reaches the authorize '
        'call', () {
      final spy = _SpyAuthorize();
      AoidRedirectFlow(
        endpoints: AoidEndpoints.parse('https://auth.aocyber.localhost'),
        clientId: 'c',
        redirectUri: 'edenbiz://auth',
        options: AoidRedirectOptions(
          callbackScheme: 'edenbiz',
          preferEphemeral: true,
        ),
        authorize: spy.call,
        generatePkce: _fixedPkce,
      ).start();

      expect(spy.optionsSeen.single.preferEphemeral, isTrue);
    });

    test('the browser is launched SYNCHRONOUSLY from the caller — no await '
        'first', () {
      final b = _build();
      b.flow.start(); // deliberately not awaited

      expect(
        b.spy.calls,
        1,
        reason:
            'an await before the launch ends the user-gesture task and the '
            'browser stops treating window.open as user-initiated — which is '
            'what gets the popup blocked in the first place',
      );
    });

    test('one start() launches the browser exactly once', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.complete('edenbiz://auth?code=THE_CODE&state=$_kState');
      await future;

      expect(b.spy.calls, 1);
    });
  });

  group('item 12: cancellation is a distinct, non-error outcome', () {
    test('a dismissed session returns AoidRedirectCancelled', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.completeError(
        PlatformException(code: 'CANCELED', message: 'User canceled'),
      );

      expect(await future, isA<AoidRedirectCancelled>());
    });

    test('cancelling does NOT throw — it returns', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.completeError(
        PlatformException(code: 'CANCELED', message: 'User canceled'),
      );

      await expectLater(future, completes);
    });

    test('a user denial at the IdP is a cancellation, not a failure', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.complete('edenbiz://auth?error=access_denied');

      expect(await future, isA<AoidRedirectCancelled>());
    });

    test('a genuine platform failure is NOT a cancellation', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.completeError(
        PlatformException(code: 'error', message: 'Timeout waiting'),
      );

      expect(await future, isA<AoidRedirectUnavailable>());
    });

    test('cancelling re-opens nothing', () async {
      final b = _build();
      final future = b.flow.start();
      b.spy.completer.completeError(
        PlatformException(code: 'CANCELED', message: 'User canceled'),
      );
      await future;
      await pumpEventQueue();

      expect(
        b.spy.calls,
        1,
        reason: 'a cancelled hop must never silently re-open the browser',
      );
    });
  });

  // ------------------------------------------------------------------
  // riverpod 3 automatic retry — the fourth screening item.
  //
  // riverpod 3 retries a failed provider by DEFAULT: 10 attempts over a
  // 38.2-second window, declining only ProviderException and Error. Dart's
  // Error means PROGRAMMING faults, so every ordinary Exception IS retried,
  // and.when(error:) is unreachable throughout because each retry returns
  // the provider to AsyncLoading.
  //
  // This flow's defence is STRUCTURAL rather than configurational: it returns
  // a value for every expected outcome, so there is no error for riverpod to
  // retry, at any call site, without anyone remembering an opt-out.
  // ------------------------------------------------------------------
  group('retry safety: no expected outcome is ever thrown', () {
    Future<void> expectReturns(void Function(_SpyAuthorize) drive) async {
      final b = _build();
      final future = b.flow.start();
      drive(b.spy);
      final outcome = await future;
      expect(outcome, isA<AoidRedirectOutcome>());
    }

    test('user cancellation returns', () async {
      await expectReturns(
        (s) => s.completer.completeError(
          PlatformException(code: 'CANCELED', message: 'x'),
        ),
      );
    });

    test('a plain Exception from the launcher returns', () async {
      // THE case riverpod 3 would retry ten times over 38 seconds.
      await expectReturns(
        (s) => s.completer.completeError(Exception('socket died')),
      );
    });

    test('a StateError from the launcher returns', () async {
      await expectReturns((s) => s.completer.completeError(StateError('bad')));
    });

    test('a token-bearing callback returns', () async {
      await expectReturns(
        (s) => s.completer.complete(
          'edenbiz://auth?code=c&state=$_kState&${'access'}_token=t',
        ),
      );
    });

    test('a state mismatch returns', () async {
      await expectReturns(
        (s) => s.completer.complete('edenbiz://auth?code=c&state=wrong'),
      );
    });

    test('a malformed callback returns', () async {
      await expectReturns((s) => s.completer.complete('::: not a url :::'));
    });

    test('a synchronously-throwing launcher returns', () async {
      final flow = AoidRedirectFlow(
        endpoints: AoidEndpoints.parse('https://auth.aocyber.localhost'),
        clientId: 'c',
        redirectUri: 'edenbiz://auth',
        options: AoidRedirectOptions(callbackScheme: 'edenbiz'),
        authorize:
            ({required url, required callbackUrlScheme, required options}) =>
                throw Exception('no browser'),
        generatePkce: _fixedPkce,
      );

      expect(await flow.start(), isA<AoidRedirectUnavailable>());
    });

    test('resume() never throws either', () {
      expect(
        _build().flow.resume('::: not a url :::'),
        isA<AoidRedirectOutcome>(),
      );
      expect(_build().flow.resume(''), isA<AoidRedirectOutcome>());
    });

    test('the flow adds no provider — the firewall holds over flow/', () {
      // Stated as a test so the DECISION is visible where the behaviour is:
      // this work introduces no provider at all, which is why there is no
      // per-provider `retry:` override to review.
      //
      // Comments are stripped first. These files deliberately NAME the retry
      // behaviour in order to explain why the flow is built to make it
      // unreachable, and a whole-file `contains` cannot tell a DECLARATION
      // from a MENTION — the same problem every Stage B change hit. The positive
      // control below is what keeps the
      // stripper honest.
      final files = Directory('lib/src/aoid/flow')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(files, hasLength(greaterThanOrEqualTo(5)));

      final hits = files
          .where(
            (f) => stripComments(f.readAsStringSync()).contains('riverpod'),
          )
          .map((f) => f.path)
          .toList();
      expect(hits, isEmpty, reason: 'a provider appeared under flow/: $hits');
    });

    test('positive control: the stripper does not hide a real import', () {
      const planted = '''
// this comment mentions riverpod and must NOT count
import 'package:flutter_riverpod/flutter_riverpod.dart';
''';
      expect(stripComments(planted), contains('riverpod'));
      expect(
        stripComments('// riverpod, only in a comment\nfinal x = 1;'),
        isNot(contains('riverpod')),
      );
    });
  });
}
