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
import Foundation
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
    print("Benchmark target: \(BenchmarkConfig.fromEnvironment().mode)")

    // Inject our tracing so we can capture timing data
    LiveKitSDK.setTracing(benchmarkTracer)

    // The SDK logs to OSLog by default, which a benchmark run never shows. `LK_BENCH_SDK_LOG=1`
    // routes it to stdout so a run can be read for what the SDK itself reported — SDP munges
    // being rejected, descriptions failing to apply — alongside libwebrtc's own output.
    // `PrintLogger` rather than `setLoggerStandardOutput()`: that one is deprecated and sets an
    // `OSLogger` level, so it never reaches stdout.
    if Timeline.isSDKLoggingEnabled {
        LiveKitSDK.setLogger(TimelineLogger())
    }

    // Metric configuration: focus on wall clock time
    Benchmark.defaultConfiguration = .init(
        metrics: .default,
        timeUnits: .milliseconds,
        warmupIterations: 5,
        scalingFactor: .one,
        maxDuration: .seconds(300),
        maxIterations: 100,
    )

    // Register all benchmark suites
    connectionBenchmarks()
    sessionLifecycleBenchmarks()
    lateJoinerBenchmarks()
    dataChannelBenchmarks()
    rpcBenchmarks()
}
