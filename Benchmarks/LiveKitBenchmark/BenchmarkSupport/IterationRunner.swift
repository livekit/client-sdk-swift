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

/// 1 per iteration that never reached a milestone, 0 per iteration that completed.
///
/// Declared once rather than per benchmark file: an arm that intermittently fails must not read
/// as a reliable one with fewer samples, and that only holds if every arm reports it the same way.
let mFailed: BenchmarkMetric = .custom("failed_iterations", polarity: .prefersSmaller, useScalingFactor: false)

/// Runs `body` once per scaled iteration, committing its samples only when it completes and
/// recording `failed_iterations` either way.
///
/// Shared by BM-SESSION and BM-JOIN so the two cannot drift in how they count a failure, or in
/// whether a partial iteration contributes to the percentiles.
///
/// - Parameter settle: Time to leave the SFU alone between iterations, after the rooms are torn
///   down and before the next identity joins.
func runIterations(_ benchmark: Benchmark,
                   variant: String,
                   settle: UInt64 = 2_000_000_000,
                   _ body: (MeasurementBuffer) async throws -> Void) async throws
{
    for _ in benchmark.scaledIterations {
        // The framework discards warmup samples, so a failure there is not part of the failure
        // rate these lines would otherwise be counted as.
        let isWarmup = benchmark.currentIteration < benchmark.configuration.warmupIterations
        let samples = MeasurementBuffer()
        let failure = try await runTolerantly { try await body(samples) }
        if failure == nil { samples.commit(to: benchmark) }
        reportFailure(failure, variant: variant, isWarmup: isWarmup)
        benchmark.measurement(mFailed, failure == nil ? 0 : 1)
        try await Task.sleep(nanoseconds: settle)
    }
}

/// Reports a failed iteration, naming the milestone that never arrived.
///
/// Printed rather than only recorded as a metric: the milestone is the useful part and the
/// results table has no column for it. One line per failure — the framework invokes a benchmark
/// body once per iteration, so there is no point in the body at which a per-variant total could
/// be known. Count the lines to get the rate.
func reportFailure(_ reason: String?, variant: String, isWarmup: Bool = false) {
    guard let reason else { return }
    guard !isWarmup else {
        print("[\(variant)] warmup iteration failed (not counted): \(reason)")
        return
    }
    // `BenchmarkTimeout.description` already names the milestone it never reached, so one
    // message covers a timeout and any other error without claiming a milestone for the latter.
    print("[\(variant)] iteration failed: \(reason)")
}
