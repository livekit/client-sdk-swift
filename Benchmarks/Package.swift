// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "LiveKitBenchmark",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(name: "client-sdk-swift", path: "../"),
        .package(url: "https://github.com/livekit/livekit-uniffi-xcframework.git", from: "0.0.1"),
        // No Jemalloc trait: jemalloc's malloc-zone hooks crash on macOS 26 (malloc metrics read 0 without it)
        .package(url: "https://github.com/ordo-one/benchmark.git", from: "1.29.0", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "LiveKitBenchmark",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift"),
                .product(name: "LiveKitUniFFI", package: "livekit-uniffi-xcframework"),
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "LiveKitBenchmark",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark"),
            ],
        ),
    ],
)
