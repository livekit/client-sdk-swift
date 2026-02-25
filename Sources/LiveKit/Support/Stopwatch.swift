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

// MARK: - Span

/// A single timed operation with named events recorded at
/// protocol-level boundaries.
public final class Span: @unchecked Sendable, CustomStringConvertible {
    public struct Entry: Sendable {
        public let label: String
        public let time: TimeInterval
    }

    public let name: String
    public let start: TimeInterval

    private struct State {
        var entries: [Entry] = []
    }

    private let _state = StateSync(State())

    public init(name: String) {
        self.name = name
        start = ProcessInfo.processInfo.systemUptime
    }

    /// Record a named event. Timestamp defaults to now if not provided.
    public func record(_ event: String, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        _state.mutate { $0.entries.append(Entry(label: event, time: time)) }
    }

    /// A snapshot of all recorded entries.
    public var entries: [Entry] {
        _state.entries
    }

    /// Total elapsed time from start to the last recorded entry.
    public func total() -> TimeInterval {
        _state.read { state in
            guard let last = state.entries.last else { return 0 }
            return last.time - start
        }
    }

    /// Returns the time of a named event relative to `start`, in microseconds.
    public func microseconds(for label: String) -> Int64? {
        _state.read { state in
            guard let entry = state.entries.first(where: { $0.label == label }) else { return nil }
            return Int64((entry.time - start) * 1_000_000)
        }
    }

    /// All events as label → microseconds relative to `start`.
    public var splitMicroseconds: [String: Int64] {
        _state.read { state in
            var result = [String: Int64]()
            for entry in state.entries {
                result[entry.label] = Int64((entry.time - start) * 1_000_000)
            }
            return result
        }
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        let snapshot = _state.entries
        var parts = [String]()
        var prev = start
        for entry in snapshot {
            let diff = entry.time - prev
            prev = entry.time
            parts.append("\(entry.label) +\(diff.rounded(to: 2))s")
        }
        parts.append("total \((prev - start).rounded(to: 2))s")
        return "Span(\(name), \(parts.joined(separator: ", ")))"
    }
}

// MARK: - Tracer

/// A shared timing instrument that manages named ``Span``s for SDK operations.
///
/// The SDK calls ``record(_:span:)`` at protocol-level boundaries during
/// connect, publish, and other operations. The default implementation
/// (``Stopwatch``) logs completed spans. Inject a custom implementation
/// via ``LiveKitSDK/setTracer(_:)`` to capture timing data programmatically.
///
/// This follows the same injection pattern as ``Logger``.
public protocol Tracer: Sendable {
    /// Begin a new span, replacing any existing span with the same name.
    @discardableResult
    func beginSpan(_ name: String) -> Span

    /// Record a named event in the given span.
    func record(_ event: String, span name: String)

    /// End the named span and handle the completed timing data.
    func endSpan(_ name: String)

    /// Retrieve the active span with the given name, if any.
    func span(_ name: String) -> Span?
}

// MARK: - Stopwatch

/// Default ``Tracer`` that logs completed spans via the SDK's logger.
public final class Stopwatch: Tracer, @unchecked Sendable {
    private struct State {
        var spans: [String: Span] = [:]
    }

    private let _state = StateSync(State())

    public init() {}

    @discardableResult
    public func beginSpan(_ name: String) -> Span {
        let span = Span(name: name)
        _state.mutate { $0.spans[name] = span }
        return span
    }

    public func record(_ event: String, span name: String) {
        let time = ProcessInfo.processInfo.systemUptime
        let span = _state.read { $0.spans[name] }
        span?.record(event, at: time)
    }

    public func endSpan(_ name: String) {
        let span = _state.mutate { $0.spans.removeValue(forKey: name) }
        if let span {
            sharedLogger.log("\(span)", .debug, type: Stopwatch.self)
        }
    }

    public func span(_ name: String) -> Span? {
        _state.read { $0.spans[name] }
    }
}
