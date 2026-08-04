// Web half of the conditional import in aoid_verifier_stash.dart.
//
// Binds to the browser's SESSION-scoped store — `window.sessionStorage` —
// which is cleared when the tab closes. It is deliberately NOT the persistent
// origin-wide store; see aoid_verifier_stash.dart's header for the full
// argument, which is the only reason this exception to D4 is acceptable.
//
// `dart:js_interop` rather than `package:web`: `web` is only a TRANSITIVE
// dependency here, and importing it directly would trip
// depend_on_referenced_packages. The SDK library needs no pubspec change.

import 'dart:js_interop';

import 'aoid_verifier_stash.dart';

@JS('window.sessionStorage')
external _SessionStorage get _sessionStorage;

/// The three `Storage` members this file uses. Nothing else is bound, so
/// nothing else can be reached from here.
extension type _SessionStorage._(JSObject _) implements JSObject {
  external void setItem(String key, String value);
  external String? getItem(String key);
  external void removeItem(String key);
}

/// Session-scoped, single-key persistence for the PKCE `code_verifier`.
class AoidSessionStorageVerifierStash implements AoidVerifierStash {
  const AoidSessionStorageVerifierStash();

  @override
  void save(String codeVerifier) =>
      _sessionStorage.setItem(AoidVerifierStash.storageKey, codeVerifier);

  @override
  String? restore() => _sessionStorage.getItem(AoidVerifierStash.storageKey);

  @override
  void clear() => _sessionStorage.removeItem(AoidVerifierStash.storageKey);
}

AoidVerifierStash createPlatformVerifierStash() =>
    const AoidSessionStorageVerifierStash();
