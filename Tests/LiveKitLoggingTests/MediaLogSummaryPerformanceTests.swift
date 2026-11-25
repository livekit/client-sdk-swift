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

import Foundation
@testable import LiveKit
import Testing

struct MediaLogSummaryPerformanceTests {
    @Test func repeatedDiagnosticCost() {
        let emissions = StateSync(0)
        let summary = MediaLogSummary(type: Self.self, automatic: false, now: { 0 }, emit: { _, _ in
            emissions.mutate { $0 += 1 }
        })
        // A microbenchmark of the exceptional path only; not a media or device performance gate.
        for _ in 0 ..< 1000 {
            summary.record(.unsafeDimensions, "warmup")
        }
        var samples: [Double] = []
        for _ in 0 ..< 5 {
            let started = DispatchTime.now().uptimeNanoseconds
            for _ in 0 ..< 100_000 {
                summary.record(.unsafeDimensions, "invalid dimensions")
            }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 100_000)
        }
        summary.finish()
        #expect(emissions.copy() == 2)
        print("MediaLogSummary ns/repeated event (five 100000-event samples): \(samples)")
    }
}
