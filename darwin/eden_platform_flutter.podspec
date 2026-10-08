#
# eden_platform_flutter — the iOS + macOS native half.
#
# Derived from `flutter create --template=plugin --platforms=ios,macos` at
# Flutter 3.47.5, with its separate ios/ and macos/ podspecs merged into the
# sharedDarwinSource layout (pubspec: `sharedDarwinSource: true`), so ONE
# Swift source serves both platforms. Consumers using CocoaPods get this file;
# consumers with Swift Package Manager enabled get
# eden_platform_flutter/Package.swift instead. Keep the two in step.
#
# DEPLOYMENT FLOORS: iOS 13.0 / macOS 10.15. These are deliberately LOW (the
# 3.47.5 app template defaults to iOS 15.0 / macOS 12.0), the same floors the
# Flutter team's own shared-darwin plugins use, and the floor of
# ASAuthorizationController itself. The passkey API is gated at RUNTIME with
# `@available(iOS 16.0, macOS 13.0, *)`, so adding this plugin forces no
# consumer to raise its own minimum. Never raise these to make something
# compile — narrow an `#if os(...)` or an `@available` instead.
#
# DEPENDENCIES: the Flutter engine and the AuthenticationServices system
# framework. Nothing else — no third-party pod.
#
Pod::Spec.new do |s|
  s.name             = 'eden_platform_flutter'
  s.version          = '0.0.1'
  s.summary          = 'iOS/macOS native half of eden_platform_flutter: AOID platform passkey assertions.'
  s.description      = <<-DESC
Platform-authenticator passkey assertions for the AOID sign-in SDK, through
Apple's AuthenticationServices (ASAuthorizationPlatformPublicKeyCredentialProvider).
                       DESC
  s.homepage         = 'https://aocyber.ai'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'AO Cyber Systems'
  s.source           = { :path => '.' }
  s.source_files     = 'eden_platform_flutter/Sources/eden_platform_flutter/**/*.swift'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.frameworks       = 'AuthenticationServices'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # Minimal privacy manifest: AuthenticationServices assertions use no
  # Required-Reason API and collect nothing.
  s.resource_bundles = {'eden_platform_flutter_privacy' => ['eden_platform_flutter/Sources/eden_platform_flutter/PrivacyInfo.xcprivacy']}
end
