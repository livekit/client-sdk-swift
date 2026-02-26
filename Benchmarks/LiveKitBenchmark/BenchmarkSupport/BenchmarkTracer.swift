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
/// The default ``NoopTracer`` discards spans. ``LoggingTracer`` logs and removes spans when they end. This implementation
/// keeps them so benchmarks can extract timing data after operations complete.
///
/// Inject via `LiveKitSDK.setTracer()` before running benchmarks.

extension Span {
    /// All events as label → microseconds relative to `start`.
    var splitMicroseconds: [String: Int64] {
        var result = [String: Int64]()
        for entry in entries {
            result[entry.label] = Int64((entry.time - start) * 1_000_000)
        }
        return result
    }
}

final class BenchmarkTracer: Tracing, @unchecked Sendable {
    private struct State {
        var completedSpans: [String: Span] = [:]
    }

    private let _state = StateSync(State())

    @discardableResult
    func beginSpan(_ name: String) -> Span {
        let span = Span(label: name)
        span.onEnd = { [weak self] span in
            self?._state.mutate { $0.completedSpans[name] = span }
        }
        return span
    }

    /// Retrieve the most recently completed span with the given name.
    func completedSpan(_ name: String) -> Span? {
        _state.read { $0.completedSpans[name] }
    }

    /// Clear all completed spans.
    func reset() {
        _state.mutate { $0.completedSpans.removeAll() }
    }
}
