// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "LiveKitBenchmark",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(name: "client-sdk-swift", path: "../"),
        .package(url: "https://github.com/livekit/livekit-ffi-xcframework.git", from: "0.0.1"),
        .package(url: "https://github.com/ordo-one/benchmark.git", from: "1.35.0"),
    ],
    targets: [
        .executableTarget(
            name: "LiveKitBenchmark",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift"),
                .product(name: "LiveKitFFI", package: "livekit-ffi-xcframework"),
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "LiveKitBenchmark",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark"),
            ],
        ),
    ],
)
