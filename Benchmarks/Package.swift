// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "LiveKitBenchmark",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "../"),
        .package(url: "https://github.com/ordo-one/package-benchmark.git", from: "1.29.0"),
        .package(url: "https://github.com/livekit/livekit-uniffi-xcframework.git", exact: "0.0.5"),
    ],
    targets: [
        .executableTarget(
            name: "LiveKitBenchmark",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift"),
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "LiveKitUniFFI", package: "livekit-uniffi-xcframework"),
            ],
            path: "LiveKitBenchmark",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
            ]
        ),
    ]
)
