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
        .package(url: "https://github.com/ordo-one/package-benchmark.git", from: "1.29.0"),
    ],
    targets: [
        .executableTarget(
            name: "LiveKitBenchmark",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift"),
                .product(name: "LiveKitUniFFI", package: "livekit-uniffi-xcframework"),
                .product(name: "Benchmark", package: "package-benchmark"),
            ],
            path: "LiveKitBenchmark",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
            ]
        ),
    ]
)
