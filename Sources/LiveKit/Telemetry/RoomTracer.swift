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
#if DEBUG
import os.signpost
#endif

/// Room-scoped span factory.
///
/// The app-facing ``Tracing`` (``LiveKitSDK/setTracing(_:)``) still creates every ``Span`` — its
/// slot is untouched — and the Room's sinks then observe it: the telemetry core, which gives the
/// span its identity under the session trace, and os_signpost in debug builds. The provider
/// fan-out OTel, swift-log and Timber all use, at Room scope because the session is the trace.
final class RoomTracer: @unchecked Sendable {
    /// No sinks: the app tracer alone (before a connection exists).
    static let detached = RoomTracer(sinks: [])

    private let sinks: [SpanSink]

    init(sinks: [SpanSink]) {
        self.sinks = sinks
    }

    @discardableResult
    func beginSpan(_ name: String, kind: SpanKind = .internal, parent: Span? = nil) -> Span {
        let span = sharedTracing.beginSpan(name)
        span.kind = kind
        span.parent = parent
        span.sinks = sinks
        for sink in sinks {
            sink.spanDidBegin(span)
        }
        return span
    }
}

#if DEBUG
/// Spans as Instruments "Points of Interest" intervals — the same bridge opentelemetry-swift's
/// SignPostIntegration provides. Debug builds only; no backend needed to see a session's timeline.
final class SignpostSpanSink: SpanSink, @unchecked Sendable {
    private let log = OSLog(subsystem: "io.livekit", category: .pointsOfInterest)
    private let ids = StateSync<[ObjectIdentifier: OSSignpostID]>([:])

    func spanDidBegin(_ span: Span) {
        let id = OSSignpostID(log: log)
        ids.mutate { $0[ObjectIdentifier(span)] = id }
        os_signpost(.begin, log: log, name: "Span", signpostID: id, "%{public}@", span.label)
    }

    func span(_ span: Span, didRecord entry: Span.Entry) {
        guard let id = ids.read({ $0[ObjectIdentifier(span)] }) else { return }
        os_signpost(.event, log: log, name: "Span", signpostID: id, "%{public}@", entry.label)
    }

    func spanDidEnd(_ span: Span) {
        guard let id = ids.mutate({ $0.removeValue(forKey: ObjectIdentifier(span)) }) else { return }
        os_signpost(.end, log: log, name: "Span", signpostID: id, "%{public}@", String(describing: span.outcome ?? .ok))
    }
}
#endif
