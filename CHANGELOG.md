## 0.2.0

* Added passkey sign-in to the sealed `AoidLoginForm` on iOS 16+ and macOS 13+. When the AOID
  server advertises `webauthn_discoverable`, the form shows "Sign in with a passkey" and runs the
  discoverable ceremony through the operating system's passkey sheet. The assertion goes from the OS
  straight to AOID and never enters app code. The form's constructor is unchanged.
* New public API: `AoidNativeFlow.canUsePasskey`, `AoidNativeFlow.signInWithPasskey` (called by the
  form; the authenticator type it takes is not exported), the closed `AoidPasskeyOutcome` enum, and
  `AoidLoginTheme.passkeyLabel`.
* The package is now a Flutter plugin for iOS and macOS. One Swift source under `darwin/` links only
  Apple's `AuthenticationServices` framework and builds down to iOS 13 and macOS 10.15. After
  upgrading, run `pod install` in `ios/` and `macos/`, or let Swift Package Manager resolve the
  package. Web, Android, Windows and Linux builds are unchanged, and no package was added to the
  dependency graph.
* Consumer prerequisites (the Associated Domains entitlement `webcredentials:<your AOID host>` on iOS
  and macOS, an `apple-app-site-association` file on the AOID host listing `<TeamID>.<bundle id>`,
  and a provisioning profile on macOS) are in `lib/src/aoid/README.md`, under "Passkey sign-in (iOS
  and macOS)".
* `AoidMfaForm`: the `webauthn_discoverable` factor is labelled "Passkey" instead of "Security key",
  and the source comment no longer claims that an in-app path completes WebAuthn at the second-factor
  step. Behaviour is unchanged: choosing either WebAuthn factor still shows "Use your security key to
  continue."
* Not provided: passkeys on web (sign in through the hosted page), Android, hardware security keys,
  and security keys at the second-factor step. The passkey button is omitted on each of these.

## 0.0.1

* TODO: Describe initial release.
