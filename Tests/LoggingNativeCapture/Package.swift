// swift-tools-version:6.2
import PackageDescription

// Kept outside the main test process because Rust logger installation and opt-out are global.
let package = Package(
    name: "LoggingNativeCapture",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "LiveKit", path: "../.."),
        .package(url: "https://github.com/livekit/livekit-ffi-xcframework.git", exact: "0.15.0"),
    ],
    targets: [.testTarget(name: "NativeTests", dependencies: [
        .product(name: "LiveKit", package: "LiveKit"),
        .product(name: "LiveKitFFI", package: "livekit-ffi-xcframework"),
    ], path: "Tests")],
    swiftLanguageModes: [.v6],
)
