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
/// nothing drives the drains' state callbacks and their open latches would never resolve — leaving
/// every `Room.send(dataPacket:)` to wait out `.defaultPublisherDataChannelOpen` first.
class MockDataChannelPair: DataChannelPair, @unchecked Sendable {
    var packetHandler: (Livekit_DataPacket) -> Void

    /// Pre-resolved, so the send gate passes immediately. One for both kinds: nothing here
    /// distinguishes them.
    private let alwaysOpen: AsyncCompleter<Void> = {
        let completer = AsyncCompleter<Void>(label: "Mock data channel open", defaultTimeout: .defaultPublisherDataChannelOpen)
        completer.resume(returning: ())
        return completer
    }()

    init(packetHandler: @escaping (Livekit_DataPacket) -> Void) {
        self.packetHandler = packetHandler
    }

    override func whenOpen(kind _: Livekit_DataPacket_Kind) -> AsyncCompleter<Void> { alwaysOpen }

    override func send(dataPacket packet: Livekit_DataPacket) async throws {
        packetHandler(packet)
    }
}
