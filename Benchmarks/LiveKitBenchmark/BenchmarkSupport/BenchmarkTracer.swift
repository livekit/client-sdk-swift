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

/// A ``Tracer`` implementation that retains completed spans for benchmark analysis.
///
/// The default ``Stopwatch`` removes spans when they end. This implementation
/// keeps them so benchmarks can extract timing data after operations complete.
///
/// Inject via `LiveKitSDK.setTracer()` before running benchmarks.
final class BenchmarkTracer: Tracer, @unchecked Sendable {
    private struct State {
        var activeSpans: [String: Span] = [:]
        var completedSpans: [String: Span] = [:]
    }

    private let _state = StateSync(State())

    @discardableResult
    func beginSpan(_ name: String) -> Span {
        let span = Span(name: name)
        _state.mutate { $0.activeSpans[name] = span }
        return span
    }

    func record(_ event: String, span name: String) {
        let time = ProcessInfo.processInfo.systemUptime
        let span = _state.read { $0.activeSpans[name] }
        span?.record(event, at: time)
    }

    func endSpan(_ name: String) {
        _state.mutate { state in
            if let span = state.activeSpans.removeValue(forKey: name) {
                state.completedSpans[name] = span
            }
        }
    }

    func span(_ name: String) -> Span? {
        _state.read { $0.activeSpans[name] }
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
