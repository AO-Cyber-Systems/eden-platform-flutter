// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

// eden_platform_flutter — the iOS + macOS native half,
// for consumers with Swift Package Manager enabled. CocoaPods consumers use
// ../eden_platform_flutter.podspec instead; keep the two in step.
//
// Derived from the Flutter 3.47.5 plugin template (`flutter create
// --template=plugin --platforms=ios,macos`), merging its ios/ and macos/
// Package.swift files into the shared darwin/ layout. The FlutterFramework
// dependency is the template's form: the Flutter tool provides that package
// next to the plugin when it links plugins into the app.
//
// DEPLOYMENT FLOORS iOS 13.0 / macOS 10.15 — deliberately low; the passkey API
// is gated at runtime with `@available(iOS 16.0, macOS 13.0, *)`, so this
// package forces no consumer to raise its minimum. See the podspec header.

import PackageDescription

let package = Package(
    name: "eden_platform_flutter",
    platforms: [
        .iOS("13.0"),
        .macOS("10.15"),
    ],
    products: [
        .library(name: "eden-platform-flutter", targets: ["eden_platform_flutter"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "eden_platform_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // Minimal privacy manifest: no Required-Reason API, no data collected.
                .process("PrivacyInfo.xcprivacy")
            ],
            linkerSettings: [
                // System framework only: no third-party package.
                .linkedFramework("AuthenticationServices")
            ]
        )
    ]
)
