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
@testable import LiveKit
import LiveKitFFI

extension Room {
    /// Records every data stream packet this connected room sends, on its way to the real
    /// transport, so a test against a server can check the framing the core picked. The core still
    /// decides from the room's own view of its participants.
    func recordDataStreamPackets() throws -> StateSync<[Livekit_DataPacket]> {
        guard let connection = _state.stage.connection else {
            throw LiveKitError(.invalidState, message: "Room is not connected")
        }
        let packets = StateSync<[Livekit_DataPacket]>([])
        let registry = DataStreams.Registry(room: self)
        connection.outgoingDataStreams.mutate {
            let recorder = PacketRecorder(forwardingTo: $0.delegate, packets: packets)
            $0 = DataStreams.Outgoing(manager: OutgoingDataStreamManager(delegate: recorder, registry: registry), delegate: $0.delegate)
        }
        return packets
    }
}

/// Keeps a decoded copy of each packet, then hands it to the room's own delegate.
private final class PacketRecorder: OutgoingDataStreamManagerDelegate, Sendable {
    private let delegate: DataStreams.OutgoingDelegate
    private let packets: StateSync<[Livekit_DataPacket]>

    init(forwardingTo delegate: DataStreams.OutgoingDelegate, packets: StateSync<[Livekit_DataPacket]>) {
        self.delegate = delegate
        self.packets = packets
    }

    func onPacketsAvailable(packets emitted: [Data]) async throws {
        let decoded = emitted.compactMap { try? Livekit_DataPacket(serializedBytes: $0) }
        packets.mutate { $0.append(contentsOf: decoded) }
        try await delegate.onPacketsAvailable(packets: emitted)
    }
}
