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

internal import LiveKitUniFFI
import Foundation

// MARK: - Span

/// How a span's operation ended. OTel's status knows only unset/ok/error; `cancelled` is a
/// first-class outcome here because a user hanging up mid-connect is not a failure.
public enum SpanOutcome: Sendable, Equatable {
    case ok
    case error
    case cancelled
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

/// One attempt at an SDK operation: a timed interval with checkpoints, attributes and an outcome.
///
/// The span itself lives in the telemetry core (timing, checkpoints, attributes, outcome, export,
/// and the one-line description); this class is the Swift handle plus what only the runtime can
/// do: the task-local ``current`` span and the ``onEnd`` hook. Every call is synchronous, so a
/// checkpoint is stamped where it happened.
public final class Span: @unchecked Sendable, Equatable, CustomStringConvertible {
    /// The core's span. Replaced once, at creation, when the SDK binds an app tracer's span.
    var core: TelemetrySpan

    /// The open span this one nests under, if any.
    public internal(set) var parent: Span?

    /// Handler called once when the span ends. Set by the tracer at creation time.
    public var onEnd: (@Sendable (Span) -> Void)?

    /// The span the current task is working inside, if any. Bound by the SDK around operations
    /// (`connect`, a reconnect cycle) so child spans nest and warn/error records point at it
    /// without any handle being passed around; does not cross the WebRTC callback boundary.
    @TaskLocal public static var current: Span?

    private let fired = StateSync(false)

    init(core: TelemetrySpan) {
        self.core = core
    }

    /// A detached span: timed and described, exported only if the SDK binds it to a session.
    public convenience init(label: String) {
        self.init(core: TelemetrySpan.detached(name: .custom(name: label)))
    }

    public var label: String { core.label() }
    public var isEnded: Bool { core.isEnded() }
    public var outcome: SpanOutcome? { core.outcome().map(SpanOutcome.init) }
    /// Identity in the telemetry session's trace; `nil` for detached spans.
    public var context: SpanContext? {
        core.context().map { SpanContext(traceId: $0.traceId, spanId: $0.spanId) }
    }

    /// The open bag; keys follow `SPEC.md`. Replaces an existing key.
    public func setAttribute(_ key: String, _ value: SpanAttribute) {
        core.setAttribute(key: key, value: value.lowered)
    }

    /// The track a publish or subscribe span is about; call again once the sid is known.
    func setTrack(_ kind: Track.Kind, source: Track.Source, sid: Track.Sid? = nil, remoteIdentity: String? = nil) {
        guard let kind = kind.telemetry else { return }
        core.setTrack(track: SpanTrack(sid: sid?.stringValue, kind: kind, source: String(describing: source), remoteIdentity: remoteIdentity))
    }

    /// End this span successfully. Equivalent to ``end(outcome:error:)`` with `.ok`.
    public func end() {
        end(outcome: .ok)
    }

    /// End this span with an outcome, firing ``onEnd`` exactly once.
    public func end(outcome: SpanOutcome, error: Error? = nil) {
        let alreadyFired = fired.mutate { was -> Bool in
            defer { was = true }
            return was
        }
        guard !alreadyFired else { return }
        core.end(outcome: outcome.lowered, error: error.map(Span.errorType))
        onEnd?(self)
        onEnd = nil
    }

    /// An app-defined checkpoint, stamped now.
    public func record(_ label: String) {
        core.step(step: .custom(name: label))
    }

    /// An SDK checkpoint, stamped now.
    func step(_ step: SpanStep) {
        core.step(step: step)
    }

    /// Seconds from start to the end, or to the last checkpoint while running.
    public func total() -> TimeInterval {
        core.totalSecs()
    }

    /// `error.type` for a span: the LiveKit error case when it is one, else the Swift type name.
    static func errorType(_ error: Error) -> String {
        if let error = error as? LiveKitError { return "LiveKitError.\(error.type)" }
        if error is CancellationError { return "CancellationError" }
        return String(describing: type(of: error))
    }

    // MARK: - Equatable

    /// One span is one attempt: identity, not content.
    public static func == (lhs: Span, rhs: Span) -> Bool {
        lhs === rhs
    }

    // MARK: - CustomStringConvertible

    /// The core's line, identical on every platform: `lk.connect: ws_open +1.49s, …, total 1.83s, ok`.
    public var description: String { core.describe() }
}

extension SpanOutcome {
    var lowered: LiveKitUniFFI.SpanOutcome {
        switch self {
        case .ok: .ok
        case .error: .error
        case .cancelled: .cancelled
        }
    }

    init(_ core: LiveKitUniFFI.SpanOutcome) {
        switch core {
        case .ok: self = .ok
        case .error: self = .error
        case .cancelled: self = .cancelled
        }
    }
}

// MARK: - Stopwatch typealias

@available(*, deprecated, renamed: "Span")
public typealias Stopwatch = Span

// MARK: - Tracing

/// A factory that creates ``Span``s for SDK operations.
///
/// The default ``TelemetryTracer`` logs completed spans at debug level and, when telemetry is
/// on, ships them. App-defined spans are named freely; the SDK's own use the core's vocabulary.
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

@available(*, deprecated, renamed: "TelemetryTracer")
public typealias LoggingTracer = TelemetryTracer
