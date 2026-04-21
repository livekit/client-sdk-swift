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
import LiveKit

/// A ``Tracing`` implementation that retains completed spans for benchmark analysis.
///
/// The default ``LoggingTracer`` logs spans when they end. This implementation
/// keeps them so benchmarks can extract timing data after operations complete.
///
/// Inject via `LiveKitSDK.setTracing()` before running benchmarks.

extension Span {
    /// All events as label → milliseconds relative to `start`.
    var splitMilliseconds: [String: Int64] {
        var result = [String: Int64]()
        for entry in entries {
            result[entry.label] = Int64((entry.time - start) * 1000)
        }
        return result
    }
}

final class BenchmarkTracer: Tracing, @unchecked Sendable {
    private let _completedSpans = StateSync<[String: Span]>([:])

    @discardableResult
    func beginSpan(_ name: String) -> Span {
        let span = Span(label: name)
        span.onEnd = { [weak self] span in
            self?._completedSpans.mutate { $0[name] = span }
        }
        return span
    }

    /// Retrieve the most recently completed span with the given name.
    func completedSpan(_ name: String) -> Span? {
        _completedSpans.read { $0[name] }
    }

    /// Clear all completed spans.
    func reset() {
        _completedSpans.mutate { $0.removeAll() }
    }
}
