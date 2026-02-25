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
    ],
    targets: [
        .executableTarget(
            name: "LiveKitBenchmark",
            dependencies: [
                .product(name: "LiveKit", package: "client-sdk-swift"),
                .product(name: "Benchmark", package: "package-benchmark"),
            ],
            path: "LiveKitBenchmark",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
            ]
        ),
    ]
)
