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

/// The SDK's tracer, and the default ``Tracing``.
///
/// As the process default it creates spans and logs them at debug level when they end (what
/// `LoggingTracer` did). Bound to a Room's telemetry session it also gives every span it creates
/// an identity in that session's trace — the ``Span`` then reports its checkpoints and end to the
/// session itself, so there is nothing to attach afterwards. An app-injected ``Tracing``
/// (``LiveKitSDK/setTracing(_:)``) still creates the span objects; the binding is added on top.
public final class TelemetryTracer: Tracing, Sendable {
    /// No session: the app tracer alone (before a connection exists, or telemetry off).
    static let detached = TelemetryTracer(session: nil)

    private let session: TelemetrySession?

    /// The process default: plain spans, logged at debug level when they end.
    public init() {
        session = nil
    }

    init(session: TelemetrySession?) {
        self.session = session
    }

    // MARK: Tracing

    /// The protocol entry point; same path as ``beginSpan(_:kind:parent:)`` with `kind: .internal`.
    @discardableResult
    public func beginSpan(_ name: String) -> Span {
        beginSpan(name, kind: .internal)
    }

    /// Create a span — through the app's tracer if one was injected, ours otherwise — and, when
    /// telemetry is on, file it under the session: identity now, checkpoints and outcome from the
    /// span itself. `kind` is required so a one-argument call cannot bypass this path.
    @discardableResult
    func beginSpan(_ name: String, kind: SpanKind, parent: Span? = Span.current) -> Span {
        let span: Span
        if sharedTracing is TelemetryTracer {
            span = Span(label: name)
            span.onEnd = { span in
                sharedLogger.log("\(span)", .debug, type: TelemetryTracer.self)
            }
        } else {
            span = sharedTracing.beginSpan(name)
        }
        span.kind = kind
        span.parent = parent
        if let session {
            let id = session.beginSpan(name: name, kind: kind == .client ? .client : .internal, parent: parent?.context?.spanId)
            span.context = SpanContext(traceId: session.traceId(), spanId: id)
            span.telemetry = (session, id)
        }
        return span
    }
}
