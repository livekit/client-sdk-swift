// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LiveKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "LiveKit",
            targets: ["LiveKit"]
        ),
    ],
    dependencies: [
        .package(name: "WebRTC", url: "https://github.com/webrtc-sdk/Specs.git", .upToNextMajor(from:"92.4515.11")),
        .package(name: "SwiftProtobuf", url: "https://github.com/apple/swift-protobuf.git", .upToNextMajor(from: "1.18.0")),
        .package(name: "Promises", url: "https://github.com/google/promises.git", .upToNextMajor(from: "2.0.0")),
        .package(url: "https://github.com/apple/swift-log.git", .upToNextMajor(from: "1.4.2")),
    ],
    targets: [
        .target(
            name: "LiveKit",
            dependencies: [
                "WebRTC", "SwiftProtobuf", "Promises",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "LiveKitTests",
            dependencies: ["LiveKit"]
        ),
    ]
)
