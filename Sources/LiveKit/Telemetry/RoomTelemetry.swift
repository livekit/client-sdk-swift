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

/// The SDK-area instrument of one Room: its session identity (`lk.room.*`, `lk.participant.*`),
/// and its app-defined events, filed under the session the Room got from the pipeline (its spans
/// are created and filed by ``TelemetryTracer``). Created with the
/// Room, so pre-connect work is captured; lives as long as the Room, connections come and go
/// inside it. Stateless itself: the session handle is thread-safe, so everything here is
/// callable from wherever the SDK runs.
@Telemetry
final class RoomTelemetry: TelemetryInstrument {
    nonisolated let session: TelemetrySession

    nonisolated init(session: TelemetrySession) {
        self.session = session
    }

    func start() {}

    /// The Room is going away: ship what is queued.
    func stop() {
        Telemetry.flush()
    }

    /// The session's trace id: 32 hex characters, the handle support asks for.
    nonisolated var traceId: String { session.traceId() }

    /// Session identity, attached to every record from now on.
    nonisolated func roomDidConnect(_ room: Room) {
        set("lk.room.sid", room.sid?.stringValue)
        set("lk.room.name", room.name)
        set("lk.participant.sid", room.localParticipant.sid?.stringValue)
        set("lk.participant.identity", room.localParticipant.identity?.stringValue)
    }

    /// The connection ended: ship what is queued. The session stays with the Room — a reconnect
    /// later is the same call.
    nonisolated func connectionDidEnd() {
        Telemetry.flush()
    }

    /// A consumer-defined event; the core namespaces it under `custom.`.
    nonisolated func emitCustom(_ name: String, attributes: [String: SpanAttribute]) {
        session.emitCustom(name: name, attributes: attributes.lowered)
    }

    private nonisolated func set(_ key: String, _ value: String?) {
        session.setAttribute(key: key, value: value.map { .str($0) })
    }
}
