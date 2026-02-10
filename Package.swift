// swift-tools-version:5.9
// (Xcode15.0+)

import PackageDescription

let package = Package(
    name: "LiveKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .macCatalyst(.v14),
        .tvOS(.v17),
    ],
    products: [
        .library(
            name: "LiveKit",
            targets: ["LiveKit"]
        ),
    ],
    dependencies: [
        // LK-Prefixed Dynamic WebRTC XCFramework
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "137.7151.13"),
        .package(url: "https://github.com/livekit/livekit-uniffi-xcframework.git", exact: "0.0.5"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.31.0"),
        .package(url: "https://github.com/apple/swift-collections.git", "1.1.0" ..< "1.3.0"),
        // Only used for DocC generation
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "LKObjCHelpers",
            publicHeadersPath: "include"
        ),
        .target(
            name: "LiveKit",
            dependencies: [
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
                .product(name: "LiveKitUniFFI", package: "livekit-uniffi-xcframework"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "OrderedCollections", package: "swift-collections"),
                "LKObjCHelpers",
            ],
            exclude: [
                "Broadcast/NOTICE",
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("AccessLevelOnImport"),
            ]
        ),
        .target(
            name: "LiveKitTestSupport",
            dependencies: [
                "LiveKit",
            ],
            path: "Tests/LiveKitTestSupport"
        ),
        .testTarget(
            name: "LiveKitCoreTests",
            dependencies: [
                "LiveKit",
                "LiveKitTestSupport",
            ]
        ),
        .testTarget(
            name: "LiveKitAudioTests",
            dependencies: [
                "LiveKit",
                "LiveKitTestSupport",
            ]
        ),
        .testTarget(
            name: "LiveKitObjCTests",
            dependencies: [
                "LiveKit",
                "LiveKitTestSupport",
            ]
        ),
    ],
    swiftLanguageVersions: [
        .v5,
    ]
)
