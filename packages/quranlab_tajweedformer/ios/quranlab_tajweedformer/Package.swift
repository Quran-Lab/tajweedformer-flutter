// swift-tools-version: 5.9
// TajweedFormer for Flutter on iOS: the plugin's Swift side, over the Apple SDK (Swift package tajweedformer-apple).
// The SDK ships only as a Swift package, so this plugin needs Flutter's Swift Package Manager integration (on by
// default since Flutter 3.44). FlutterFramework needs Flutter 3.41 or later.

import Foundation
import PackageDescription

// The Apple SDK: the Swift package tajweedformer-apple, any 4.x from 4.0.0, through its public API only (the Core comes
// inside it as a binary target). QURANLAB_APPLE_SDK=<folder> builds against a local copy of that package instead, with
// its QuranLabCore.xcframework, before a release or for a Core under test. The folder's name is
// the package's identity in SwiftPM, so it must be named tajweedformer-apple.
let appleSDK: Package.Dependency = {
    if let folder = ProcessInfo.processInfo.environment["QURANLAB_APPLE_SDK"], !folder.isEmpty {
        return .package(path: folder)
    }
    return .package(url: "https://github.com/Quran-Lab/tajweedformer-apple", from: "4.0.0")
}()

let package = Package(
    name: "quranlab_tajweedformer",
    platforms: [
        // the Apple SDK's own minimum
        .iOS("15.0")
    ],
    products: [
        .library(name: "quranlab-tajweedformer", targets: ["quranlab_tajweedformer"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        appleSDK,
    ],
    targets: [
        .target(
            name: "quranlab_tajweedformer",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "TajweedFormer", package: "tajweedformer-apple"),
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
