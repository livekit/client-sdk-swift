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

/// How a span's operation ended. OTel's status knows only unset/ok/error; `cancelled` is a
/// first-class outcome here because a user hanging up mid-connect is not a failure.
public enum SpanOutcome: Sendable, Equatable {
    case ok
    case error
    case cancelled
}

public enum SpanKind: Sendable, Equatable {
    /// An operation inside the SDK (publish, subscribe).
    case `internal`
    /// A call to the SFU that waits for its answer (connect, reconnect).
    case client
}

/// A typed span attribute; keys follow `SPEC.md` (`lk.connect.attempt`, `lk.reconnect.mode`, …).
public enum SpanAttribute: Sendable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
}

/// The identity a sink gave the span: the session's trace and this attempt.
public struct SpanContext: Sendable, Equatable {
    public let traceId: String
    public let spanId: UInt64
}

/// One attempt at an SDK operation: a timed interval with checkpoints (``record(_:at:)``),
/// attributes, and an ``outcome`` set when it ends.
///
/// Spans are created by the app-facing ``Tracing`` (``LiveKitSDK/setTracing(_:)``) and observed
/// by the Room's sinks — the telemetry core, and os_signpost in debug builds — so one span
/// reaches every consumer without any of them owning it.
public final class Span: @unchecked Sendable, Equatable, CustomStringConvertible {
    public struct Entry: Equatable, Sendable {
        public let label: String
        public let time: TimeInterval
    }

    private struct State {
        var ended = false
        var outcome: SpanOutcome?
        var errorType: String?
        var entries: [Entry] = []
        var attributes: [String: SpanAttribute] = [:]
    }

    public let label: String
    public let start: TimeInterval

    /// Set by the tracer that created the span.
    public internal(set) var kind: SpanKind = .internal
    /// The open span this one nests under, if any.
    public internal(set) var parent: Span?
    /// Identity assigned by the Room's telemetry; `nil` for local-only spans.
    public internal(set) var context: SpanContext?

    /// Handler called once when the span ends. Set by the tracer at creation time.
    public var onEnd: (@Sendable (Span) -> Void)?

    /// Handler called for every ``record(_:at:)``. Set by the Room's telemetry, if on.
    var onRecord: (@Sendable (Span, Entry) -> Void)?

    /// The span the current task is working inside, if any. Bound by the SDK around operations
    /// (`connect`, a reconnect cycle) so child spans nest and warn/error records point at it
    /// without any handle being passed around; does not cross the WebRTC callback boundary.
    @TaskLocal public static var current: Span?

    private let _state = StateSync(State())

    public init(label: String) {
        self.label = label
        start = ProcessInfo.processInfo.systemUptime
    }

    public var isEnded: Bool { _state.ended }
    public var outcome: SpanOutcome? { _state.outcome }
    /// `error.type` of the failure the span ended with, e.g. `LiveKitError.timedOut`.
    public var errorType: String? { _state.errorType }
    public var attributes: [String: SpanAttribute] { _state.attributes }

    public func setAttribute(_ key: String, _ value: SpanAttribute) {
        _state.mutate { $0.attributes[key] = value }
    }

    /// End this span successfully. Equivalent to ``end(outcome:error:)`` with `.ok`.
    public func end() {
        end(outcome: .ok)
    }

    /// End this span with an outcome, firing ``onEnd`` exactly once.
    public func end(outcome: SpanOutcome, error: Error? = nil) {
        let first = _state.mutate { state -> Bool in
            guard !state.ended else { return false }
            state.ended = true
            state.outcome = outcome
            state.errorType = error.map(Span.errorType)
            return true
        }
        guard first else { return }
        onEnd?(self)
        onEnd = nil
    }

    /// Record a named checkpoint. Timestamp defaults to now if not provided.
    public func record(_ event: String, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let entry = Entry(label: event, time: time)
        _state.mutate { $0.entries.append(entry) }
        onRecord?(self, entry)
    }

    @available(*, deprecated, renamed: "record(_:at:)")
    public func split(label: String = "") {
        record(label)
    }

    /// A snapshot of all recorded entries.
    public var entries: [Entry] {
        _state.entries
    }

    @available(*, deprecated, renamed: "entries")
    public var splits: [Entry] { entries }

    /// Total elapsed time from start to the last recorded entry.
    public func total() -> TimeInterval {
        guard let last = entries.last else { return 0 }
        return last.time - start
    }

    /// Spec value for a track kind (`Track.Kind` is `@objc`, so `String(describing:)` is not usable).
    static func kindName(_ kind: Track.Kind) -> String {
        switch kind {
        case .audio: "audio"
        case .video: "video"
        case .none: "none"
        }
    }

    /// `error.type` for a span: the LiveKit error case when it is one, else the Swift type name.
    static func errorType(_ error: Error) -> String {
        if let error = error as? LiveKitError { return "LiveKitError.\(error.type)" }
        if error is CancellationError { return "CancellationError" }
        return String(describing: type(of: error))
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
        if let outcome { parts.append(String(describing: outcome)) }
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
/// Inject a custom implementation via ``LiveKitSDK/setTracing(_:)`` to
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
