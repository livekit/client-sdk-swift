/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Benchmark
import LiveKit

/// Shared tracer that retains completed spans for benchmark analysis.
let benchmarkTracer = BenchmarkTracer()

/// Entry point for all LiveKit benchmarks.
///
/// This closure is discovered by the `BenchmarkPlugin` and triggers
/// registration of all benchmark suites. Each suite is defined in its
/// own file and referenced here to ensure it is linked into the executable.
///
/// Run with: `swift package benchmark`
let benchmarks: @Sendable () -> Void = {
    // Inject our tracer so we can capture timing data
    LiveKitSDK.setTracer(benchmarkTracer)

    // Metric configuration: focus on wall clock time
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock],
        warmupIterations: 5,
        scalingFactor: .one,
        maxDuration: .seconds(300),
        maxIterations: 30
    )

    // Register all benchmark suites
    connectionBenchmarks()
    dataChannelBenchmarks()
    rpcBenchmarks()
}
