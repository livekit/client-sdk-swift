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

@testable import LiveKit

/// Mock ``DataChannelPair`` to intercept outgoing packets.
///
/// Stands in for a pair whose channels are already open. It has no real `LKRTCDataChannel`s, so
/// nothing ever drives `handleStateChange` and the open latches would never resolve — leaving
/// `Room.ensureDataChannelReady(kind:)` to wait out its full timeout on every send.
class MockDataChannelPair: DataChannelPair, @unchecked Sendable {
    var packetHandler: (Livekit_DataPacket) -> Void

    /// Pre-resolved, so the send gate passes immediately.
    private let alwaysOpen: AsyncCompleter<Void> = {
        let completer = AsyncCompleter<Void>(label: "Mock data channel open", defaultTimeout: .defaultPublisherDataChannelOpen)
        completer.resume(returning: ())
        return completer
    }()

    init(packetHandler: @escaping (Livekit_DataPacket) -> Void) {
        self.packetHandler = packetHandler
    }

    override func openCompleter(for _: Livekit_DataPacket_Kind) -> AsyncCompleter<Void> {
        alwaysOpen
    }

    override func isOpen(kind _: Livekit_DataPacket_Kind) -> Bool { true }

    override var isOpen: Bool { true }

    override func send(dataPacket packet: Livekit_DataPacket) async throws {
        packetHandler(packet)
    }
}
