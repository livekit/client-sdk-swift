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
/// As the process default it creates spans and logs the core's one-line description at debug
/// level when they end. Bound to a Room's telemetry session, every span it creates is the core's:
/// named from the shared vocabulary, timed and exported there. An app-injected ``Tracing``
/// (``LiveKitSDK/setTracing(_:)``) still creates the `Span` handles it wants to observe.
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

    /// The protocol entry point: an app-defined span.
    @discardableResult
    public func beginSpan(_ name: String) -> Span {
        beginSpan(.custom(name: name))
    }

    /// An SDK span, stamped now in the core. Bound to the session when telemetry is on, detached
    /// otherwise; an injected app tracer still creates and observes the `Span`, the core's span
    /// is handed to it before anything is recorded.
    @discardableResult
    func beginSpan(_ name: SpanName, parent: Span? = Span.current) -> Span {
        let core = session?.start(name: name, parent: parent?.core) ?? TelemetrySpan.detached(name: name)
        let span: Span
        if sharedTracing is TelemetryTracer {
            span = Span(core: core)
            span.onEnd = { span in
                sharedLogger.log(span.description, .debug, type: TelemetryTracer.self)
            }
        } else {
            span = sharedTracing.beginSpan(core.label())
            span.core = core
        }
        span.parent = parent
        return span
    }
}
