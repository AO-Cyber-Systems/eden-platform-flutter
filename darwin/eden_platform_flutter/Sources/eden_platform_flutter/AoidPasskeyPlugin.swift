// The native half of the AOID passkey channel (Objective 52, TRD 52-02).
//
// WHY AN IN-PACKAGE CHANNEL, NOT THE `passkeys` PUB PLUGIN (52-RESEARCH §3):
// eden_platform_flutter is consumed by ~18 apps on every platform. The
// `passkeys` plugin's web half calls `window.close()` in any web app that has
// not loaded a third-party CDN script, and its Android half adds Play Services
// and minSdk 23 to every Android consumer. This file is the whole native
// surface instead: iOS + macOS only (pubspec `sharedDarwinSource`), the
// AuthenticationServices system framework only, no third-party dependency.
//
// THE CONTRACT IS FROZEN — the Dart half (lib/src/aoid/passkey/
// aoid_platform_passkey_authenticator.dart, TRD 52-01) carries an identical
// copy. Methods `isSupported` -> Bool and `getAssertion` {rpId, challenge,
// userVerification?, timeoutMs?} -> {credentialId, clientDataJSON,
// authenticatorData, signature, userHandle}; error codes cancelled,
// not_associated, unsupported, invalid_options, busy, no_window, failed. A
// rename on either side fails only at runtime.
//
// WHY RAW BYTES: AOID verifies a signature over
// authenticatorData || SHA-256(clientDataJSON) — the exact bytes the OS
// produced. Every returned field is unpadded base64url of the OS's `Data`,
// as-is. clientDataJSON is never parsed into an object or a String and
// re-serialised; the Dart half never decodes the strings either.
//
// WHY CANCEL AND NO-CREDENTIAL ARE ONE CODE: in the modal flow Apple reports
// "the user dismissed the sheet" and "there is no passkey for this relying
// party" as the same `ASAuthorizationError.canceled`. Telling them apart needs
// the prefer-immediately-available-credentials request option, which also
// hides the cross-device (QR) sheet. Both readings are non-enumerating, so
// both map to `cancelled` (52-RESEARCH §4, assumption A3).
//
// WHY ONLY THE PLATFORM PROVIDER, MODALLY: the goal is the platform
// authenticator (synced passkeys). Hardware security keys are out of scope
// (assumption A4), so the security-key credential provider is not used. The
// sealed form starts sign-in from a button, so the request is modal
// (`performRequests()`); the server's `mediation: "conditional"` is a browser
// autofill hint and the autofill-assisted request is not used either.
//
// NO OS TEXT CROSSES THE CHANNEL: every FlutterError carries one fixed,
// generic message. The OS error text is read in exactly one place — to choose
// `not_associated` — and is never forwarded.
//
// `timeoutMs` has no equivalent on a platform assertion request; it is
// accepted and ignored (no timer is invented).

#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import FlutterMacOS
import AppKit
#endif
import AuthenticationServices

public final class AoidPasskeyPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(
      name: "eden_platform_flutter/aoid_passkey",
      binaryMessenger: messenger
    )
    registrar.addMethodCallDelegate(AoidPasskeyPlugin(), channel: channel)
  }

  /// Strong reference to the in-flight `AoidAssertionRequest` for the
  /// request's whole lifetime. ASAuthorizationController holds its delegate
  /// weakly: without this the delegate is deallocated, the completion never
  /// arrives, and the Dart future hangs forever. Typed `AnyObject` because the
  /// request class only exists on iOS 16 / macOS 13.
  private var inFlight: AnyObject?

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      if #available(iOS 16.0, macOS 13.0, *) {
        result(true)
      } else {
        result(false)
      }
    case "getAssertion":
      getAssertion(call.arguments, reply: AoidOnceResult(result))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func getAssertion(_ arguments: Any?, reply: AoidOnceResult) {
    guard
      let args = arguments as? [String: Any],
      let rpId = args["rpId"] as? String, !rpId.isEmpty,
      let challengeText = args["challenge"] as? String,
      let challenge = Data(aoidBase64URL: challengeText), !challenge.isEmpty
    else {
      reply.error("invalid_options")
      return
    }
    let userVerification = args["userVerification"] as? String
    // args["timeoutMs"]: accepted and ignored (see the header).

    guard #available(iOS 16.0, macOS 13.0, *) else {
      reply.error("unsupported")
      return
    }
    if inFlight != nil {
      reply.error("busy")
      return
    }
    guard let anchor = AoidPasskeyPlugin.presentationAnchor() else {
      reply.error("no_window")
      return
    }

    let request = AoidAssertionRequest(
      rpId: rpId,
      challenge: challenge,
      userVerification: userVerification,
      anchor: anchor
    ) { [weak self] outcome in
      self?.inFlight = nil
      switch outcome {
      case .asserted(let fields):
        reply.success(fields)
      case .notAsserted(let code):
        reply.error(code)
      }
    }
    inFlight = request
    request.perform()
  }

  /// Where the system sheet is presented. Never force-unwrapped: no window
  /// means `no_window`, not a crash.
  static func presentationAnchor() -> ASPresentationAnchor? {
    #if os(iOS)
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    guard let windows = scene?.windows else { return nil }
    return windows.first { $0.isKeyWindow } ?? windows.first
    #else
    return NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
    #endif
  }

  /// The one way an error leaves this plugin: a contract code and a FIXED
  /// generic message. Never OS text, never details.
  static func flutterError(_ code: String) -> FlutterError {
    return FlutterError(code: code, message: "Passkey sign-in did not complete.", details: nil)
  }
}

/// The closed error table: ONE switch from an authorization error to a
/// contract code. Everything not named here is `failed`.
enum AoidPasskeyErrorTable {
  static func code(for error: Error) -> String {
    guard let authorizationError = error as? ASAuthorizationError else {
      return "failed"
    }
    switch authorizationError.code {
    case .canceled:
      // Dismissed OR no credential — Apple does not distinguish them here.
      return "cancelled"
    case .failed
    where authorizationError.localizedDescription.contains("is not associated with domain"):
      // Matched ONLY to choose the code; the text itself is never forwarded.
      // Locale-dependent by nature (Apple exposes no dedicated code for it).
      return "not_associated"
    default:
      return "failed"
    }
  }
}

/// A FlutterResult that can be invoked exactly once. A second invocation
/// crashes the engine, so later calls are dropped. Always delivers on the
/// main (platform) thread.
final class AoidOnceResult {
  private var result: FlutterResult?

  init(_ result: @escaping FlutterResult) {
    self.result = result
  }

  func success(_ value: Any?) {
    guard let deliver = result else { return }
    result = nil
    if Thread.isMainThread {
      deliver(value)
    } else {
      DispatchQueue.main.async { deliver(value) }
    }
  }

  func error(_ code: String) {
    success(AoidPasskeyPlugin.flutterError(code))
  }
}

enum AoidAssertionOutcome {
  case asserted([String: String])
  case notAsserted(String)
}

/// One modal platform-passkey assertion. Lives (held by the plugin's
/// `inFlight`) until the controller calls back exactly once.
@available(iOS 16.0, macOS 13.0, *)
final class AoidAssertionRequest: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding
{
  private let controller: ASAuthorizationController
  private let anchor: ASPresentationAnchor
  private var completion: ((AoidAssertionOutcome) -> Void)?

  init(
    rpId: String,
    challenge: Data,
    userVerification: String?,
    anchor: ASPresentationAnchor,
    completion: @escaping (AoidAssertionOutcome) -> Void
  ) {
    let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
      relyingPartyIdentifier: rpId
    )
    let request = provider.createCredentialAssertionRequest(challenge: challenge)
    if let preference = AoidAssertionRequest.preference(userVerification) {
      request.userVerificationPreference = preference
    }
    // allowedCredentials stays EMPTY: the discoverable flow lets the user
    // pick any passkey for this relying party.
    self.controller = ASAuthorizationController(authorizationRequests: [request])
    self.anchor = anchor
    self.completion = completion
    super.init()
    controller.delegate = self
    controller.presentationContextProvider = self
  }

  func perform() {
    controller.performRequests()
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    return anchor
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    guard
      let assertion = authorization.credential
        as? ASAuthorizationPlatformPublicKeyCredentialAssertion,
      let credentialId = AoidAssertionRequest.encoded(assertion.credentialID),
      let clientDataJSON = AoidAssertionRequest.encoded(assertion.rawClientDataJSON),
      let authenticatorData = AoidAssertionRequest.encoded(assertion.rawAuthenticatorData),
      let signature = AoidAssertionRequest.encoded(assertion.signature),
      // REQUIRED: AOID's discoverable finish resolves the account from the
      // user handle. A nil or empty userID is `failed`, never an empty field.
      let userHandle = AoidAssertionRequest.encoded(assertion.userID)
    else {
      finish(.notAsserted("failed"))
      return
    }
    finish(.asserted([
      "credentialId": credentialId,
      "clientDataJSON": clientDataJSON,
      "authenticatorData": authenticatorData,
      "signature": signature,
      "userHandle": userHandle,
    ]))
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithError error: Error
  ) {
    finish(.notAsserted(AoidPasskeyErrorTable.code(for: error)))
  }

  private func finish(_ outcome: AoidAssertionOutcome) {
    guard let complete = completion else { return }
    completion = nil
    complete(outcome)
  }

  /// Unpadded base64url of the OS's bytes, as-is; nil when absent or empty.
  /// Takes `Data?` so it accepts the SDK's property whether it is imported as
  /// optional or not.
  static func encoded(_ data: Data?) -> String? {
    guard let data = data, !data.isEmpty else { return nil }
    return data.aoidBase64URLString()
  }

  static func preference(_ value: String?)
    -> ASAuthorizationPublicKeyCredentialUserVerificationPreference?
  {
    switch value {
    case "required": return .required
    case "preferred": return .preferred
    case "discouraged": return .discouraged
    default: return nil  // absent or unknown: keep the OS default
    }
  }
}

extension Data {
  /// Decodes base64url, padded or not (go-webauthn emits it unpadded).
  init?(aoidBase64URL text: String) {
    var base64 = text
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while base64.hasSuffix("=") { base64.removeLast() }
    switch base64.count % 4 {
    case 1: return nil
    case 2: base64 += "=="
    case 3: base64 += "="
    default: break
    }
    self.init(base64Encoded: base64)
  }

  /// Unpadded base64url of these exact bytes.
  func aoidBase64URLString() -> String {
    return base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
