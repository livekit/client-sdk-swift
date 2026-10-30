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
import Testing

private let testKey = "test-key"

@Suite(.tags(.dataChannel, .e2ee))
struct PlaintextDataChannelTests {
    enum Payload: CaseIterable {
        case user, chatMessage, rpcRequest, rpcAck, rpcResponse, streamHeader, streamChunk, streamTrailer

        var packet: Livekit_DataPacket {
            .with {
                $0.participantSid = "PA_sender"
                $0.participantIdentity = "sender"
                switch self {
                case .user: $0.user = .with { _ in }
                case .chatMessage: $0.chatMessage = .with { _ in }
                case .rpcRequest: $0.rpcRequest = .with { _ in }
                case .rpcAck: $0.rpcAck = .with { _ in }
                case .rpcResponse: $0.rpcResponse = .with { _ in }
                case .streamHeader: $0.streamHeader = .with { _ in }
                case .streamChunk: $0.streamChunk = .with { _ in }
                case .streamTrailer: $0.streamTrailer = .with { _ in }
                }
            }
        }
    }

    enum SenderShape {
        case hiddenParticipant, customLabel, innerIdentity, serverRpc, anonymousRpc

        var packet: Livekit_DataPacket {
            .with {
                $0.user = .with { _ in }
                switch self {
                case .hiddenParticipant: $0.participantSid = "PA_hidden"
                case .customLabel: $0.participantIdentity = "sender"
                case .innerIdentity: $0.user = .with { $0.participantIdentity = "sender" }
                case .serverRpc:
                    $0.participantIdentity = UUID().uuidString
                    $0.rpcRequest = .with { _ in }
                case .anonymousRpc: $0.rpcRequest = .with { _ in }
                }
            }
        }
    }

    @Test func serverApiUserDataIsDelivered() async throws {
        let context = ReceiveContext()
        let packet = Livekit_DataPacket.with { $0.user = .with { _ in } }
        try await context.receive(packet)
        context.expect(packets: [packet], errorCount: 0)
    }

    @Test(arguments: [SenderShape.hiddenParticipant, .customLabel, .innerIdentity, .serverRpc, .anonymousRpc])
    func participantShapedPlaintextIsDropped(shape: SenderShape) async throws {
        let context = ReceiveContext()
        let packet = shape.packet
        try await context.receive(packet)
        context.expect(packets: [], errorCount: 1)
    }

    @Test(arguments: Payload.allCases, [DataChannelKind.reliable, .lossy])
    func plaintextIsDroppedAndReported(payload: Payload, channel: DataChannelKind) async throws {
        let context = ReceiveContext()
        for count in 1 ... 2 {
            try await context.receive(payload.packet, channel: channel)
            context.expect(packets: [], errorCount: count)
        }
    }

    @Test func droppedPlaintextDoesNotAdvanceReliableSequence() async throws {
        let context = ReceiveContext()
        let packet = Payload.user.packet.modifying { $0.participantSid = "PA_sender"; $0.sequence = 100 }
        try await context.receive(packet)
        #expect(context.pair.receiveStates().isEmpty)
        context.expect(packets: [], errorCount: 1)
    }

    @Test func controlPacketIsStillDelivered() async throws {
        let context = ReceiveContext()
        let packet = Livekit_DataPacket.with { $0.sipDtmf = .with { _ in } }
        try await context.receive(packet)
        context.expect(packets: [packet], errorCount: 0)
    }

    @available(*, deprecated, message: "Covers the deprecated media-only E2EEOptions")
    @Test func legacyMediaOnlyRoomDeliversPlaintext() async throws {
        let context = ReceiveContext(manager: E2EEManager(e2eeOptions: E2EEOptions(keyProvider: BaseKeyProvider(isSharedKey: true, sharedKey: testKey))))
        try #require(context.manager?.isDataChannelEncryptionEnabled == false)
        try await context.receive(Payload.user.packet)
        context.expect(packets: [Payload.user.packet], errorCount: 0)
    }

    @Test func noEncryptionDeliversPlaintext() async throws {
        let context = ReceiveContext(manager: nil)
        try await context.receive(Payload.user.packet)
        context.expect(packets: [Payload.user.packet], errorCount: 0)
    }

    @Test func togglingEncryptionAppliesPerPacket() async throws {
        let context = ReceiveContext()
        let manager = try #require(context.manager)
        manager.enableE2EE(enabled: false)
        try await context.receive(Payload.user.packet)
        context.expect(packets: [Payload.user.packet], errorCount: 0)
        manager.enableE2EE(enabled: true)
        try await context.receive(Payload.user.packet)
        context.expect(packets: [Payload.user.packet], errorCount: 1)
    }
}

private final class ReceiveContext: NSObject, DataChannelDelegate, RoomDelegate, Sendable {
    struct State {
        var packets: [Livekit_DataPacket] = []
        var encryptionTypes: [EncryptionType] = []
        var errors: [LiveKitError] = []
        var roomErrors: [LiveKitError] = []
    }

    let state = StateSync(State())
    let pair = DataChannelPair()
    let room: Room
    let manager: E2EEManager?

    init(manager: E2EEManager? = E2EEManager(options: .sharedKey(testKey))) {
        let room = Room()
        self.room = room
        self.manager = manager
        super.init()
        room.add(delegate: self)
        pair.delegates.add(delegate: room)
        pair.delegates.add(delegate: self)
        pair.set(e2eeManager: manager)
    }

    func receive(_ packet: Livekit_DataPacket, channel: DataChannelKind = .reliable) async throws {
        try pair.handle(received: packet.serializedData(), isReliable: channel == .reliable)
        await pair.delegates.notifyAsync { _ in }
        await room.delegates.notifyAsync { _ in }
    }

    func expect(packets: [Livekit_DataPacket], errorCount: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(state.packets == packets, sourceLocation: sourceLocation)
        #expect(state.encryptionTypes == Array(repeating: .none, count: packets.count), sourceLocation: sourceLocation)
        #expect(state.errors.count == errorCount, sourceLocation: sourceLocation)
        #expect(state.errors.allSatisfy { $0.type == .decryptionFailed }, sourceLocation: sourceLocation)
        #expect(state.roomErrors == state.errors, sourceLocation: sourceLocation)
    }

    func dataChannel(_: DataChannelPair, didReceiveDataPacket packet: Livekit_DataPacket, serialized _: Data?, encryptionType: EncryptionType) {
        state.mutate {
            $0.packets.append(packet)
            $0.encryptionTypes.append(encryptionType)
        }
    }

    func dataChannel(_: DataChannelPair, didFailToDecryptDataPacket _: Livekit_DataPacket, error: LiveKitError) {
        state.mutate { $0.errors.append(error) }
    }

    func room(_: Room, didFailToDecryptDataWithEror error: LiveKitError) {
        state.mutate { $0.roomErrors.append(error) }
    }
}
