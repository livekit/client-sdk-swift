// swift-tools-version:6.0
// (Xcode16.0+)

import PackageDescription

let package = Package(
    name: "LiveKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .macCatalyst(.v14),
        .visionOS(.v2),
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
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "137.7151.09"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.31.0"),
        .package(url: "https://github.com/apple/swift-collections.git", "1.1.0" ..< "1.3.0"),
        // Only used for DocC generation
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.3.0"),
        // Only used for Testing
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "4.13.4"),
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
                .product(name: "JWTKit", package: "jwt-kit"),
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
    swiftLanguageModes: [
        .v5, // opt-out from dynamic actor isolation checks
        .v6,
    ]
)
