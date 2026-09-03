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

/// Span factory for one connection. The app-facing ``Tracing`` (``LiveKitSDK/setTracing(_:)``)
/// creates every ``Span`` — its slot is untouched — and the Room's telemetry, when on, gives the
/// span its identity under the session trace and ships its checkpoints and end.
final class RoomTracer: Sendable {
    /// No telemetry: the app tracer alone (before a connection exists, or telemetry off).
    static let detached = RoomTracer(telemetry: nil)

    private let telemetry: RoomTelemetry?

    init(telemetry: RoomTelemetry?) {
        self.telemetry = telemetry
    }

    @discardableResult
    func beginSpan(_ name: String, kind: SpanKind = .internal, parent: Span? = Span.current) -> Span {
        let span = sharedTracing.beginSpan(name)
        span.kind = kind
        span.parent = parent
        telemetry?.attach(span)
        return span
    }
}
