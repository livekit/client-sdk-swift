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

/// The telemetry core's span, shared by every LiveKit SDK: names, checkpoints, timing, attributes,
/// outcome, export and the console line all live there. Swift adds only what a core cannot own.
typealias Span = TelemetrySpan

extension TelemetrySpan {
    /// The span the current task is working inside, if any. Bound by the SDK around operations
    /// (`connect`, a reconnect cycle) so child spans nest and warn/error records point at it
    /// without any handle being passed around; does not cross the WebRTC callback boundary.
    @TaskLocal static var current: TelemetrySpan?

    /// An SDK span in `scope`'s trace, stamped now in the core; detached (timed, never exported)
    /// when telemetry is off.
    static func begin(_ name: SpanName, in scope: TelemetryScope?, parent: TelemetrySpan? = TelemetrySpan.current) -> TelemetrySpan {
        scope?.start(name: name, parent: parent) ?? TelemetrySpan.detached(name: name)
    }

    /// An SDK checkpoint, stamped now in the core.
    func step(_ step: SpanStep) {
        self.step(step: step)
    }

    /// The open bag; keys follow `SPEC.md`.
    func setAttribute(_ key: String, _ value: SpanAttribute) {
        setAttribute(key: key, value: value.lowered)
    }

    /// The track a publish or subscribe span is about; call again once the sid is known.
    func setTrack(_ kind: Track.Kind, source: Track.Source, sid: Track.Sid? = nil, remoteIdentity: String? = nil) {
        guard let kind = kind.telemetry else { return }
        setTrack(track: SpanTrack(sid: sid?.stringValue, kind: kind, source: String(describing: source), remoteIdentity: remoteIdentity))
    }

    /// End successfully.
    func end() {
        end(outcome: .ok, error: nil)
    }

    /// End on a Swift error: `cancelled` for a cancellation, `error` otherwise, with the error's
    /// type as the status message.
    func end(with error: Error) {
        if error is CancellationError {
            cancel()
        } else {
            fail(error: Self.errorType(error))
        }
    }

    /// `error.type` for a span: the LiveKit error case when it is one, else the Swift type name.
    static func errorType(_ error: Error) -> String {
        if let error = error as? LiveKitError { return "LiveKitError.\(error.type)" }
        if error is CancellationError { return "CancellationError" }
        return String(describing: type(of: error))
    }
}

/// One span is one attempt: identity, not content (`Room.State` is `Equatable`).
extension TelemetrySpan: Equatable {
    static func == (lhs: TelemetrySpan, rhs: TelemetrySpan) -> Bool {
        lhs === rhs
    }
}

/// A typed span attribute; keys follow `SPEC.md` (`lk.connect.attempt`, `lk.reconnect.mode`, …).
public enum SpanAttribute: Sendable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
}

// MARK: - Tracing

/// Kept for source compatibility. The SDK's spans live in the telemetry core and are shared by
/// every LiveKit SDK; a custom tracer is no longer consulted, so ``LiveKitSDK/setTracing(_:)`` is
/// a no-op.
@available(*, deprecated, message: "Spans live in the telemetry core; setTracing is a no-op.")
public protocol Tracing: Sendable {
    func beginSpan(_ name: String)
}
