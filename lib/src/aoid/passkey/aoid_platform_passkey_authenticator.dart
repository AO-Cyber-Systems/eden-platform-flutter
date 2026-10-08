// The Dart half of the passkey platform channel.
//
// WHY A CHANNEL AND NOT THE `passkeys` PLUGIN: this package
// is consumed by ~18 apps across every platform. `passkeys_web` calls
// `window.close()` on any web app that has not loaded a third-party CDN
// script, and `passkeys_android` adds Play Services + `minSdk 23` to every
// Android consumer. A channel declared for iOS and macOS only changes no other
// platform's build, and adds no pub dependency.
//
// THE CONTRACT IS FROZEN. The Swift half (darwin/) implements the
// same names; a rename on either side fails only at runtime
// (MissingPluginException / a missing key). The contract, verbatim:
//
//   Channel:  MethodChannel('eden_platform_flutter/aoid_passkey')
//
//   isSupported   () -> bool
//   getAssertion  {rpId, challenge, userVerification?, timeoutMs?}
//                 -> {credentialId, clientDataJSON, authenticatorData,
//                     signature, userHandle}   (unpadded base64url, all five)
//   error codes   cancelled | not_associated | unsupported | invalid_options
//                 | busy | no_window | failed
//
// NOT EXPORTED, and riverpod-free: nothing here is a provider (riverpod 3's
// default retry would turn a cancelled sheet into a 38-second spinner — see
// the header of lib/src/aoid/widgets/aoid_login_form.dart).

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'aoid_passkey_authenticator.dart';

/// The frozen channel. Its name is part of the Dart/Swift contract.
const MethodChannel _frozenChannel = MethodChannel(
  'eden_platform_flutter/aoid_passkey',
);

/// [AoidPasskeyAuthenticator] over the in-package iOS/macOS platform channel
/// (`ASAuthorizationPlatformPublicKeyCredentialProvider`).
///
/// # Byte-exact by construction
///
/// AOID verifies a signature over `authenticatorData || SHA-256(clientDataJSON)`
/// — the RAW bytes the OS produced. The native half returns each of the five
/// assertion fields as unpadded base64url of those bytes, and this class only
/// places the strings into the WebAuthn JSON document with [jsonEncode]. It
/// never decodes, re-encodes or "normalises" them: a decode/encode round trip,
/// or a padding fix alone, changes the bytes and the assertion stops
/// verifying. base64url needs no JSON escaping, so [jsonEncode] emits each
/// string byte-identically. Validation is presence and non-emptiness only.
///
/// # Cancel and no-credential are one outcome
///
/// Apple's modal assertion flow reports "the user dismissed the sheet" and
/// "the user has no passkey for this relying party" as the same
/// `ASAuthorizationError.canceled`. Distinguishing them needs
/// `.preferImmediatelyAvailableCredentials`, which also hides the cross-device
/// (QR) sheet. Both map to [AoidPasskeyFailure.cancelled]; both readings are
/// non-enumerating, so conflating them is the safe choice.
///
/// # Honest availability
///
/// Only iOS and macOS ever reach the channel. Web, Android, Windows, Linux and
/// Fuchsia answer [isSupported] `false` without a call, and a consumer whose
/// app does not link the native half (no `pod install` / SwiftPM resolve)
/// answers `false` too — on every call, never cached — so a passkey button is
/// never rendered where it cannot work.
///
/// # No OS text crosses the boundary
///
/// Only a native error's CODE is read. Its message and details — OS text,
/// which for an unassociated app names the domain configuration — are never
/// looked at, and every outcome is one of the four [AoidPasskeyFailure]s.
class AoidPlatformPasskeyAuthenticator implements AoidPasskeyAuthenticator {
  /// All parameters are test seams; production code passes none.
  ///
  /// [isWeb] exists because `kIsWeb` is a compile-time constant that a VM test
  /// cannot flip. [platform] defaults to `defaultTargetPlatform`, read on each
  /// call.
  const AoidPlatformPasskeyAuthenticator({
    MethodChannel channel = _frozenChannel,
    bool isWeb = kIsWeb,
    TargetPlatform? platform,
  }) : _native = channel,
       _onWeb = isWeb,
       _platformOverride = platform;

  final MethodChannel _native;
  final bool _onWeb;
  final TargetPlatform? _platformOverride;

  /// iOS and macOS are the only platforms that declare the native half
  /// (pubspec `flutter.plugin.platforms`). Nothing else may touch the channel.
  bool get _reachesNative {
    if (_onWeb) return false;
    final platform = _platformOverride ?? defaultTargetPlatform;
    return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
  }

  @override
  Future<bool> isSupported() async {
    if (!_reachesNative) return false;
    try {
      final answer = await _native.invokeMethod<bool>('isSupported');
      return answer ?? false;
    } on MissingPluginException {
      // Not a PlatformException subclass — caught on its own.
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<AoidPasskeyAttempt> getAssertion(
    Map<String, dynamic> publicKey,
  ) async {
    if (!_reachesNative) return _not(AoidPasskeyFailure.unsupported);

    final rpId = publicKey['rpId'];
    final challenge = publicKey['challenge'];
    if (rpId is! String || rpId.isEmpty) return _not(AoidPasskeyFailure.failed);
    if (challenge is! String || challenge.isEmpty) {
      return _not(AoidPasskeyFailure.failed);
    }

    // Only these four keys cross. Strings verbatim (the challenge keeps its
    // padding, or lack of it); absent optional values are OMITTED, never sent
    // as null. `timeoutMs` has no ASAuthorization equivalent and the native
    // half ignores it; it is forwarded so the contract stays complete.
    // `allowCredentials` is empty for the discoverable flow and `mediation`
    // is a browser autofill hint — neither is forwarded.
    final userVerification = publicKey['userVerification'];
    final timeout = publicKey['timeout'];
    final arguments = <String, Object?>{
      'rpId': rpId,
      'challenge': challenge,
      if (userVerification is String) 'userVerification': userVerification,
      if (timeout is int) 'timeoutMs': timeout,
    };

    final Object? reply;
    try {
      reply = await _native.invokeMethod<Object?>('getAssertion', arguments);
    } on PlatformException catch (error) {
      return _not(_failureFor(error.code));
    } on MissingPluginException {
      return _not(AoidPasskeyFailure.unsupported);
    }

    if (reply is! Map) return _not(AoidPasskeyFailure.failed);
    final credentialId = _present(reply, 'credentialId');
    final clientDataJSON = _present(reply, 'clientDataJSON');
    final authenticatorData = _present(reply, 'authenticatorData');
    final signature = _present(reply, 'signature');
    final userHandle = _present(reply, 'userHandle');
    // userHandle above all: AOID's discoverable finish resolves the account
    // from it, so an assertion without one can only be rejected.
    if (credentialId == null ||
        clientDataJSON == null ||
        authenticatorData == null ||
        signature == null ||
        userHandle == null) {
      return _not(AoidPasskeyFailure.failed);
    }

    // jsonEncode of a map LITERAL: key order is the literal's order and the
    // escaping is correct. Never build this by string interpolation.
    return AoidPasskeyAsserted(
      jsonEncode(<String, Object?>{
        'id': credentialId,
        'rawId': credentialId,
        'type': 'public-key',
        'authenticatorAttachment': 'platform',
        'response': <String, Object?>{
          'clientDataJSON': clientDataJSON,
          'authenticatorData': authenticatorData,
          'signature': signature,
          'userHandle': userHandle,
        },
        'clientExtensionResults': <String, Object?>{},
      }),
    );
  }

  /// [key]'s value when it is a non-empty String, else null. Presence and
  /// non-emptiness ONLY: the value is never decoded "to validate" it.
  static String? _present(Map<Object?, Object?> reply, String key) {
    final value = reply[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// The closed error table. Only the CODE is read; the exception's message
  /// and details are never looked at, so no OS text can cross this line.
  static AoidPasskeyFailure _failureFor(String code) => switch (code) {
    'cancelled' => AoidPasskeyFailure.cancelled,
    'not_associated' => AoidPasskeyFailure.notAssociated,
    'unsupported' => AoidPasskeyFailure.unsupported,
    // invalid_options, busy, no_window, failed, and any code a future native
    // half might invent.
    _ => AoidPasskeyFailure.failed,
  };

  static AoidPasskeyNotAsserted _not(AoidPasskeyFailure reason) =>
      AoidPasskeyNotAsserted(reason);
}
