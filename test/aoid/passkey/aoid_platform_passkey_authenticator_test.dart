// TRD 52-01 test-list items 1-11 — the Dart half of the passkey channel.
//
// The channel contract is FROZEN (52-01 / 52-02 carry identical copies): a
// rename on either side is a silent runtime failure, so these tests mock the
// channel by its literal name rather than by a shared constant.
//
// Every fixture below is hand-written (`no_llm_test_data`). The assertion
// strings deliberately contain `-` and `_` — the two base64url characters that
// differ from standard base64 — so a decode/re-encode through the wrong
// alphabet, or a padding "fix", changes the bytes and fails item 8.

import 'dart:convert';

import 'package:eden_platform_flutter/src/aoid/passkey/aoid_passkey_authenticator.dart';
import 'package:eden_platform_flutter/src/aoid/passkey/aoid_platform_passkey_authenticator.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The frozen channel name, spelled out (not imported) on purpose.
const MethodChannel _channel = MethodChannel(
  'eden_platform_flutter/aoid_passkey',
);

/// Every call the mock channel received, in order.
final List<MethodCall> _calls = <MethodCall>[];

/// Installs [handler] as the native side of the frozen channel, recording calls.
void _mockNative(Future<Object?> Function(MethodCall call) handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (MethodCall call) {
        _calls.add(call);
        return handler(call);
      });
}

// --- Hand-written fixtures --------------------------------------------------

const String _rpId = 'auth.aocyber.ai';

/// go-webauthn emits UNPADDED base64url; padding is optional per the contract.
const String _challengeUnpadded = 'c2lnbi1tZS1pbi1wbGVhc2U-_w';
const String _challengePadded = 'c2lnbi1tZS1pbi1wbGVhc2U-_w==';

/// The server's `webauthn_challenge.publicKey`, as 52-03 will hand it in:
/// go-webauthn `BeginDiscoverableMediatedLogin` shape (52-01 embedded context).
Map<String, dynamic> _publicKey({String challenge = _challengeUnpadded}) =>
    <String, dynamic>{
      'challenge': challenge,
      'timeout': 300000,
      'rpId': _rpId,
      'allowCredentials': <dynamic>[],
      'userVerification': 'preferred',
    };

/// A native reply for a successful assertion. Every value contains `-` and/or
/// `_`, and none carries `=` padding — exactly what the Swift half emits.
const String _credentialId = 'AQID-_cred_ID-4';
const String _clientDataJSON =
    'eyJ0eXBlIjoid2ViYXV0aG4uZ2V0IiwiY2hhbGxlbmdlIjoiYzJsbmJpMS1fdyJ9-_A';
const String _authenticatorData =
    'SZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2MFAAAAAQ-_';
const String _signature = 'MEUCIQ-_sig_nature_bytes-_AiA-_';
const String _userHandle = 'dXNlci1oYW5kbGUtXy0_-w';

Map<String, Object?> _nativeReply() => <String, Object?>{
  'credentialId': _credentialId,
  'clientDataJSON': _clientDataJSON,
  'authenticatorData': _authenticatorData,
  'signature': _signature,
  'userHandle': _userHandle,
};

/// An authenticator that WILL reach the channel (iOS, not web).
const AoidPlatformPasskeyAuthenticator _onIos =
    AoidPlatformPasskeyAuthenticator(
      isWeb: false,
      platform: TargetPlatform.iOS,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('isSupported', () {
    test('1. is false on web without touching the channel', () async {
      _mockNative((_) async => true);
      const authenticator = AoidPlatformPasskeyAuthenticator(
        isWeb: true,
        platform: TargetPlatform.iOS,
      );

      expect(await authenticator.isSupported(), isFalse);
      expect(_calls, isEmpty, reason: 'web must never reach the channel');
    });

    test('2. is false on Android, Windows, Linux and Fuchsia without touching '
        'the channel', () async {
      // The native side would say yes: only the platform gate can say no.
      _mockNative((_) async => true);
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.fuchsia,
      ]) {
        final authenticator = AoidPlatformPasskeyAuthenticator(
          isWeb: false,
          platform: platform,
        );
        expect(await authenticator.isSupported(), isFalse, reason: '$platform');
      }
      expect(_calls, isEmpty, reason: 'no non-Apple platform reaches native');
    });

    test(
      '2b. with no platform injected, reads defaultTargetPlatform',
      () async {
        _mockNative((_) async => true);
        const authenticator = AoidPlatformPasskeyAuthenticator(isWeb: false);

        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        expect(await authenticator.isSupported(), isFalse);
        expect(_calls, isEmpty);

        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        expect(await authenticator.isSupported(), isTrue);
        expect(_calls.map((c) => c.method), ['isSupported']);
      },
    );

    test('3. on iOS and macOS returns the channel\'s bool, over the FROZEN '
        'channel name and method', () async {
      // The DEFAULT channel (none injected): this pins the name the Swift half
      // registers. A rename on either side would surface here, not on a device.
      for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
        for (final answer in [true, false]) {
          _calls.clear();
          _mockNative((_) async => answer);
          final authenticator = AoidPlatformPasskeyAuthenticator(
            isWeb: false,
            platform: platform,
          );

          expect(
            await authenticator.isSupported(),
            answer,
            reason: '$platform must relay the native answer ($answer)',
          );
          expect(_calls.map((c) => c.method), ['isSupported']);
          expect(_calls.single.arguments, isNull, reason: 'no args');
        }
      }
    });

    test('4. is false (not a throw) when the native half is missing', () async {
      // A consumer that bumped the pin but never ran `pod install` / resolved
      // SwiftPM: the channel has no handler. The button must not render.
      const authenticator = AoidPlatformPasskeyAuthenticator(
        isWeb: false,
        platform: TargetPlatform.iOS,
      );

      // (a) no handler registered at all — the real "not linked" case.
      expect(await authenticator.isSupported(), isFalse);

      // (b) a handler that raises MissingPluginException explicitly.
      _mockNative((_) async => throw MissingPluginException());
      expect(await authenticator.isSupported(), isFalse);
      expect(_calls, hasLength(1));

      // And it is not cached: once the native half answers, so do we.
      _mockNative((_) async => true);
      expect(await authenticator.isSupported(), isTrue);
    });

    test(
      '4b. a PlatformException or a non-bool reply is false, never a throw',
      () async {
        _mockNative((_) async => throw PlatformException(code: 'failed'));
        expect(await _onIos.isSupported(), isFalse);

        _mockNative((_) async => null);
        expect(await _onIos.isSupported(), isFalse);
      },
    );
  });

  group('getAssertion — request', () {
    test('5. sends exactly {rpId, challenge, userVerification, timeoutMs}, '
        'strings verbatim, padding untouched', () async {
      for (final challenge in [_challengeUnpadded, _challengePadded]) {
        _calls.clear();
        _mockNative((_) async => _nativeReply());

        await _onIos.getAssertion(_publicKey(challenge: challenge));

        expect(_calls.map((c) => c.method), ['getAssertion']);
        expect(
          _calls.single.arguments,
          <String, Object?>{
            'rpId': _rpId,
            'challenge': challenge,
            'userVerification': 'preferred',
            'timeoutMs': 300000,
          },
          reason:
              'challenge "$challenge" must cross verbatim; allowCredentials '
              'and every other server key must NOT be forwarded',
        );
      }
    });

    test('6. an absent userVerification / timeout is OMITTED, never sent as '
        'null', () async {
      _mockNative((_) async => _nativeReply());

      await _onIos.getAssertion(<String, dynamic>{
        'challenge': _challengeUnpadded,
        'rpId': _rpId,
        'allowCredentials': <dynamic>[],
      });

      final sent = _calls.single.arguments as Map<Object?, Object?>;
      expect(sent, <String, Object?>{
        'rpId': _rpId,
        'challenge': _challengeUnpadded,
      });
      expect(sent.containsKey('userVerification'), isFalse);
      expect(sent.containsKey('timeoutMs'), isFalse);
    });

    test('7. a missing, empty or non-string rpId / challenge is `failed` '
        'WITHOUT a channel call', () async {
      _mockNative((_) async => _nativeReply());
      final malformed = <String, Map<String, dynamic>>{
        'rpId missing': _publicKey()..remove('rpId'),
        'rpId empty': _publicKey()..['rpId'] = '',
        'rpId not a string': _publicKey()..['rpId'] = 42,
        'challenge missing': _publicKey()..remove('challenge'),
        'challenge empty': _publicKey()..['challenge'] = '',
        'challenge not a string': _publicKey()..['challenge'] = <int>[1, 2],
      };

      for (final entry in malformed.entries) {
        final attempt = await _onIos.getAssertion(entry.value);
        expect(
          attempt,
          isA<AoidPasskeyNotAsserted>().having(
            (a) => a.reason,
            'reason',
            AoidPasskeyFailure.failed,
          ),
          reason: entry.key,
        );
      }
      expect(_calls, isEmpty, reason: 'malformed options never reach native');
    });
  });

  group('getAssertion — reply', () {
    test('8. a successful reply assembles the exact WebAuthn JSON, every '
        'native string BYTE-IDENTICAL in the raw result', () async {
      _mockNative((_) async => _nativeReply());

      final attempt = await _onIos.getAssertion(_publicKey());

      expect(attempt, isA<AoidPasskeyAsserted>());
      final raw = (attempt as AoidPasskeyAsserted).responseJson;

      // (a) RAW-STRING byte identity. A structural comparison alone would pass
      // a decode/re-encode bug (e.g. padding normalisation); this cannot.
      expect(raw, contains('"id":"$_credentialId"'));
      expect(raw, contains('"rawId":"$_credentialId"'));
      expect(raw, contains('"clientDataJSON":"$_clientDataJSON"'));
      expect(raw, contains('"authenticatorData":"$_authenticatorData"'));
      expect(raw, contains('"signature":"$_signature"'));
      expect(raw, contains('"userHandle":"$_userHandle"'));

      // (b) The whole document, exact key order (the contract's literal).
      expect(
        raw,
        '{"id":"$_credentialId","rawId":"$_credentialId","type":"public-key",'
        '"authenticatorAttachment":"platform",'
        '"response":{"clientDataJSON":"$_clientDataJSON",'
        '"authenticatorData":"$_authenticatorData",'
        '"signature":"$_signature","userHandle":"$_userHandle"},'
        '"clientExtensionResults":{}}',
      );

      // (c) Structure, as go-webauthn's ParseCredentialRequestResponseBody
      // will read it.
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded.keys.toList(), [
        'id',
        'rawId',
        'type',
        'authenticatorAttachment',
        'response',
        'clientExtensionResults',
      ]);
      expect(decoded['type'], 'public-key');
      expect((decoded['response'] as Map).keys.toList(), [
        'clientDataJSON',
        'authenticatorData',
        'signature',
        'userHandle',
      ]);
      expect(decoded['clientExtensionResults'], isEmpty);
    });

    test('9. a reply missing any field, or carrying an empty / non-string '
        'one, is `failed` — userHandle above all', () async {
      final broken = <String, Object?>{'no reply map': null};
      for (final key in _nativeReply().keys) {
        broken['$key missing'] = _nativeReply()..remove(key);
        broken['$key empty'] = _nativeReply()..[key] = '';
        broken['$key not a string'] = _nativeReply()..[key] = 7;
      }
      // userHandle is what FinishDiscoverableWebAuthnLogin resolves the
      // account from; it must never be sent empty.
      expect(broken.keys, contains('userHandle missing'));

      for (final entry in broken.entries) {
        _mockNative((_) async => entry.value);
        final attempt = await _onIos.getAssertion(_publicKey());
        expect(
          attempt,
          isA<AoidPasskeyNotAsserted>().having(
            (a) => a.reason,
            'reason',
            AoidPasskeyFailure.failed,
          ),
          reason: entry.key,
        );
      }
    });
  });

  group('getAssertion — errors', () {
    test(
      '10. every native error code maps into the closed vocabulary',
      () async {
        const table = <String, AoidPasskeyFailure>{
          'cancelled': AoidPasskeyFailure.cancelled,
          'not_associated': AoidPasskeyFailure.notAssociated,
          'unsupported': AoidPasskeyFailure.unsupported,
          'invalid_options': AoidPasskeyFailure.failed,
          'busy': AoidPasskeyFailure.failed,
          'no_window': AoidPasskeyFailure.failed,
          'failed': AoidPasskeyFailure.failed,
          'a_code_nobody_defined': AoidPasskeyFailure.failed,
        };

        for (final entry in table.entries) {
          _mockNative(
            (_) async => throw PlatformException(
              code: entry.key,
              message: 'Passkey sign-in did not complete.',
            ),
          );
          final attempt = await _onIos.getAssertion(_publicKey());
          expect(
            attempt,
            isA<AoidPasskeyNotAsserted>().having(
              (a) => a.reason,
              'reason',
              entry.value,
            ),
            reason: 'native code "${entry.key}"',
          );
        }

        // The native half is not linked (no pod install / SwiftPM resolve).
        _mockNative((_) async => throw MissingPluginException());
        expect(
          await _onIos.getAssertion(_publicKey()),
          isA<AoidPasskeyNotAsserted>().having(
            (a) => a.reason,
            'reason',
            AoidPasskeyFailure.unsupported,
          ),
          reason: 'MissingPluginException',
        );
      },
    );

    test('10b. on a platform without the API it is `unsupported` WITHOUT a '
        'channel call', () async {
      _mockNative((_) async => _nativeReply());
      for (final authenticator in const [
        AoidPlatformPasskeyAuthenticator(
          isWeb: true,
          platform: TargetPlatform.iOS,
        ),
        AoidPlatformPasskeyAuthenticator(
          isWeb: false,
          platform: TargetPlatform.android,
        ),
        AoidPlatformPasskeyAuthenticator(
          isWeb: false,
          platform: TargetPlatform.windows,
        ),
      ]) {
        expect(
          await authenticator.getAssertion(_publicKey()),
          isA<AoidPasskeyNotAsserted>().having(
            (a) => a.reason,
            'reason',
            AoidPasskeyFailure.unsupported,
          ),
        );
      }
      expect(_calls, isEmpty);
    });

    test('11. no OS text escapes: the exception message and details never '
        'reach a Dart value (or a thrown error)', () async {
      // Apple's localizedDescription for an unassociated app, verbatim shape.
      const osText =
          'The operation couldn’t be completed. Application with identifier X '
          'is not associated with domain Y';

      for (final code in [
        'not_associated',
        'failed',
        'a_code_nobody_defined',
      ]) {
        _mockNative(
          (_) async => throw PlatformException(
            code: code,
            message: osText,
            details: osText,
          ),
        );

        // Awaited directly: a rethrown PlatformException would carry osText
        // out to whatever renders the error, and fails the test here.
        final attempt = await _onIos.getAssertion(_publicKey());
        final shown = attempt.toString();

        expect(shown, isNot(contains('associated')), reason: code);
        expect(shown, isNot(contains('domain')), reason: code);
        expect(shown, isNot(contains('identifier')), reason: code);
        expect(shown, isNot(contains('couldn’t')), reason: code);
        // Exactly the closed vocabulary's spelling, nothing appended.
        final reason = (attempt as AoidPasskeyNotAsserted).reason;
        expect(shown, 'AoidPasskeyNotAsserted(${reason.name})');
      }
    });
  });
}
