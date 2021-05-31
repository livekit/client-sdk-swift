// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LiveKit",
    platforms: [
        .iOS(.v13),
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "LiveKit",
            targets: ["LiveKit"]
        ),
    ],
    dependencies: [
        .package(name: "WebRTC", url: "https://github.com/livekit/WebRTC-swift.git", .exact("1.91.0")),
        .package(name: "SwiftProtobuf", url: "https://github.com/apple/swift-protobuf.git", .upToNextMajor(from: "1.15.0")),
        .package(name: "Promises", url: "https://github.com/google/promises.git", .upToNextMajor(from: "1.2.12")),
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
