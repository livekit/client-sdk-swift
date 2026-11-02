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
        let samples = MeasurementBuffer()
        let failure = try await runTolerantly { try await body(samples) }
        if failure == nil { samples.commit(to: benchmark) }
        reportFailure(failure, variant: variant)
        benchmark.measurement(mFailed, failure == nil ? 0 : 1)
        try await Task.sleep(nanoseconds: settle)
    }
}
