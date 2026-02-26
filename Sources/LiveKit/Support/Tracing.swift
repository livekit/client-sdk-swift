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
public final class Span: @unchecked Sendable, Equatable, CustomStringConvertible {
    public struct Entry: Equatable, Sendable {
        public let label: String
        public let time: TimeInterval
    }

    public let label: String
    public let start: TimeInterval

    /// Handler called once when the span ends. Set by the tracer at creation time.
    public var onEnd: (@Sendable (Span) -> Void)?

    private var _ended = false
    private let _entries = StateSync<[Entry]>([])

    public init(label: String) {
        self.label = label
        start = ProcessInfo.processInfo.systemUptime
    }

    /// End this span, firing the ``onEnd`` handler exactly once.
    public func end() {
        guard !_ended else { return }
        _ended = true
        onEnd?(self)
        onEnd = nil
    }

    /// Record a named event. Timestamp defaults to now if not provided.
    public func record(_ event: String, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        _entries.mutate { $0.append(Entry(label: event, time: time)) }
    }

    @available(*, deprecated, renamed: "record(_:at:)")
    public func split(label: String = "") {
        record(label)
    }

    /// A snapshot of all recorded entries.
    public var entries: [Entry] {
        _entries.read { $0 }
    }

    @available(*, deprecated, renamed: "entries")
    public var splits: [Entry] { entries }

    /// Total elapsed time from start to the last recorded entry.
    public func total() -> TimeInterval {
        _entries.read { entries in
            guard let last = entries.last else { return 0 }
            return last.time - start
        }
    }

    // MARK: - Equatable

    public static func == (lhs: Span, rhs: Span) -> Bool {
        lhs.start == rhs.start && lhs.entries == rhs.entries
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        let snapshot = entries
        var parts = [String]()
        var prev = start
        for entry in snapshot {
            let diff = entry.time - prev
            prev = entry.time
            parts.append("\(entry.label) +\(diff.rounded(to: 2))s")
        }
        parts.append("total \((prev - start).rounded(to: 2))s")
        return "Span(\(label), \(parts.joined(separator: ", ")))"
    }
}

// MARK: - Stopwatch typealias

@available(*, deprecated, renamed: "Span")
public typealias Stopwatch = Span

// MARK: - Tracing

/// A factory that creates ``Span``s for SDK operations.
///
/// The default ``LoggingTracer`` logs completed spans at debug level.
/// Inject a custom implementation via ``LiveKitSDK/setTracer(_:)`` to
/// capture timing data programmatically (e.g., for benchmarks).
///
/// This follows the same injection pattern as ``Logger``.
public protocol Tracing: Sendable {
    /// Create a new span. The caller owns the returned span and is
    /// responsible for calling ``Span/end()`` when the operation completes.
    @discardableResult
    func beginSpan(_ name: String) -> Span
}

// MARK: - LoggingTracer

/// Default ``Tracing`` implementation that logs completed spans via the SDK's logger.
public final class LoggingTracer: Tracing, Sendable {
    public init() {}

    @discardableResult
    public func beginSpan(_ name: String) -> Span {
        let span = Span(label: name)
        span.onEnd = { span in
            sharedLogger.log("\(span)", .debug, type: LoggingTracer.self)
        }
        return span
    }
}
