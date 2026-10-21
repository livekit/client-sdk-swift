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

internal import LiveKitFFI

// The objects the Rust core calls into. Split from `DataStreams` itself so the coordinator file
// stays about coordination; each type here is a thin adapter that forwards across the boundary.
extension DataStreams {
    // MARK: - Incoming delegate

    /// Receives the incoming manager's stream-open callbacks and forwards them to the coordinator.
    /// A separate object because the FFI manager retains its delegate strongly; holding the
    /// coordinator weakly keeps this the weak link so teardown doesn't leak.
    final class IncomingDelegate: LiveKitFFI.IncomingDataStreamManagerDelegate, @unchecked Sendable {
        weak var coordinator: DataStreams?

        func onByteStreamOpened(reader: LiveKitFFI.ByteStreamReader, identity: String) {
            coordinator?.handleByteStreamOpened(reader, identity: identity)
        }

        func onTextStreamOpened(reader: LiveKitFFI.TextStreamReader, identity: String) {
            coordinator?.handleTextStreamOpened(reader, identity: identity)
        }

        func onStreamClosed(streamId: String, identity: String) {
            coordinator?.handleStreamClosed(streamID: streamId, identity: identity)
        }
    }

    // MARK: - Outgoing delegate

    /// Receives the outgoing manager's encoded `DataPacket`s and sends them over the reliable data
    /// channel via `Room.send(dataPacket:)` — preserving E2EE, reliable sequencing, and identity
    /// stamping. The room is held weakly to avoid retaining it through the FFI manager.
    ///
    /// The callback is `async`, which is what lets this honor the FFI's contract: it returns only
    /// once the packets have actually reached the transport. Three properties follow, none of which
    /// needs machinery on this side.
    ///
    /// - **Order.** The core awaits this call before pumping the next packet, so calls arrive — and
    ///   complete — strictly in emission order. That matters: the receiver drops a chunk that
    ///   arrives before its header and fails the stream on a non-consecutive chunk index.
    /// - **Back-pressure.** The originating `write`/`send_*` stays pending until this returns, so a
    ///   producer can't outrun the transport and queue unboundedly.
    /// - **Failures.** Throwing `PacketDeliveryError` fails that originating call with
    ///   `.sendFailed` and closes the stream, so `isOpen` reflects reality.
    ///
    /// The weak back-reference lives in a `StateSync`, so ``retire()`` can clear it while a delivery
    /// runs.
    final class OutgoingDelegate: LiveKitFFI.OutgoingDataStreamManagerDelegate, Sendable {
        private struct State {
            weak var room: Room?
        }

        private let state: StateSync<State>

        init(room: Room) {
            state = StateSync(State(room: room))
        }

        /// Fails every later delivery, as if the room were gone. A full reconnect calls this when it
        /// replaces the manager: a send that still holds the old manager, for example one in flight
        /// during the reconnect, keeps its packet pump running, and must not reach the new session.
        func retire() {
            state.mutate { $0.room = nil }
        }

        func onPacketsAvailable(packets: [Data]) async throws {
            for data in packets {
                // Read for each packet, so a retire also stops the rest of a one-shot send.
                // ponytail: a packet already inside `room.send` when the delegate retires still goes
                // out on the new session. Closing that window needs a session check in the send path.
                guard let room = state.room else {
                    throw LiveKitFFI.PacketDeliveryError.Failed(reason: "Room is gone or its session was replaced")
                }
                guard let packet = try? Livekit_DataPacket(serializedBytes: data) else {
                    throw LiveKitFFI.PacketDeliveryError.Failed(reason: "Undecodable data stream packet")
                }
                do {
                    try await room.send(dataPacket: packet)
                } catch {
                    throw LiveKitFFI.PacketDeliveryError.Failed(reason: String(describing: error))
                }
            }
        }
    }

    // MARK: - Remote participant registry

    /// Read access to the room's remote participants, used by the outgoing manager to resolve
    /// broadcast recipients and decide inline and compression eligibility from each participant's
    /// advertised client protocol and capabilities. An unknown participant reports neither, which
    /// keeps the send uncompressed and multi-packet.
    final class Registry: LiveKitFFI.RemoteParticipantRegistryDelegate, @unchecked Sendable {
        private weak var room: Room?

        init(room: Room) {
            self.room = room
        }

        private func participant(for identity: String) -> RemoteParticipant? {
            room?.remoteParticipants[Participant.Identity(from: identity)]
        }

        func remoteClientProtocol(identity: String) -> Int32 {
            Int32(participant(for: identity)?.clientProtocol.rawValue ?? 0)
        }

        func remoteCapabilities(identity: String) -> [LiveKitFFI.ClientCapability] {
            participant(for: identity)?.capabilities.map(\.ffiValue) ?? []
        }

        func remoteIdentities() -> [String] {
            guard let room else { return [] }
            return room.remoteParticipants.keys.map(\.stringValue)
        }
    }
}

extension ClientCapability {
    /// Bridges to the FFI enum. Kept here so `ClientCapability` itself stays free of any
    /// `LiveKitFFI` import, matching how the rest of the public API is layered.
    var ffiValue: LiveKitFFI.ClientCapability {
        switch self {
        case .packetTrailer: .packetTrailer
        case .compressionDeflateRaw: .compressionDeflateRaw
        }
    }
}
