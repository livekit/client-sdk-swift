// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LiveKit",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "LiveKit",
            targets: ["LiveKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/alexpiezo/WebRTC.git", .upToNextMajor(from: "1.1.31567")),
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.0"),
        .package(name: "SwiftProtobuf", url: "https://github.com/apple/swift-protobuf.git", from: "1.6.0"),
        .package(name: "Promises", url: "https://github.com/google/promises.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "LiveKit",
            dependencies: [
                "WebRTC", "Starscream", "SwiftProtobuf", "Promises",
                .product(name: "Logging", package: "swift-log")],
            path: "Sources"
        ),
        .testTarget(
            name: "LiveKitTests",
            dependencies: ["LiveKit"]),
    ]
)
