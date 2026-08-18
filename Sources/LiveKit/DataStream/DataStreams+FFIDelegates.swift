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

internal import LiveKitUniFFI

// The objects the Rust core calls into. Split from `DataStreams` itself so the coordinator file
// stays about coordination; each type here is a thin adapter that forwards across the boundary.
extension DataStreams {
    // MARK: - Incoming delegate

    /// Receives the incoming manager's stream-open callbacks and forwards them to the coordinator.
    /// A separate object because the FFI manager retains its delegate strongly; holding the
    /// coordinator weakly keeps this the weak link so teardown doesn't leak.
    final class IncomingDelegate: LiveKitUniFFI.IncomingDataStreamManagerDelegate, @unchecked Sendable {
        weak var coordinator: DataStreams?

        func onByteStreamOpened(reader: LiveKitUniFFI.ByteStreamReader, identity: String) {
            coordinator?.handleByteStreamOpened(reader, identity: identity)
        }

        func onTextStreamOpened(reader: LiveKitUniFFI.TextStreamReader, identity: String) {
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
    /// `@unchecked Sendable` for the weak back-reference alone: it is assigned in `init` and never
    /// mutated afterwards.
    final class OutgoingDelegate: LiveKitUniFFI.OutgoingDataStreamManagerDelegate, @unchecked Sendable {
        private weak var room: Room?

        init(room: Room) {
            self.room = room
        }

        func onPacketsAvailable(packets: [Data]) async throws {
            // The room is gone, so there is no transport left to fail against; the manager is being
            // torn down with it.
            guard let room else { return }

            for data in packets {
                guard let packet = try? Livekit_DataPacket(serializedBytes: data) else {
                    room.log("Failed to decode outgoing data stream packet", .warning)
                    continue
                }
                do {
                    try await room.send(dataPacket: packet)
                } catch {
                    throw LiveKitUniFFI.PacketDeliveryError.Failed(reason: String(describing: error))
                }
            }
        }
    }

    // MARK: - Remote participant registry

    /// Read access to the room's remote participants, used by the outgoing manager to resolve
    /// broadcast recipients and decide compression eligibility. Client protocol/capabilities aren't
    /// currently exposed on `RemoteParticipant`, so they default to none — compression stays off
    /// until they're wired, which is a safe default (a non-compressed send always works).
    final class Registry: LiveKitUniFFI.RemoteParticipantRegistryDelegate, @unchecked Sendable {
        private weak var room: Room?

        init(room: Room) {
            self.room = room
        }

        private func participant(for identity: String) -> RemoteParticipant? {
            room?.remoteParticipants.first { $0.key.stringValue == identity }?.value
        }

        func remoteClientProtocol(identity: String) -> Int32 {
            Int32(participant(for: identity)?.clientProtocol.rawValue ?? 0)
        }

        func remoteCapabilities(identity: String) -> [LiveKitUniFFI.ClientCapability] {
            participant(for: identity)?.capabilities.map(\.ffiValue) ?? []
        }

        func remoteIdentities() -> [String] {
            guard let room else { return [] }
            return room.remoteParticipants.keys.map(\.stringValue)
        }
    }
}

private extension ClientCapability {
    /// Bridges to the FFI enum. Kept here so `ClientCapability` itself stays free of any
    /// `LiveKitUniFFI` import, matching how the rest of the public API is layered.
    var ffiValue: LiveKitUniFFI.ClientCapability {
        switch self {
        case .packetTrailer: .packetTrailer
        case .compressionDeflateRaw: .compressionDeflateRaw
        }
    }
}
