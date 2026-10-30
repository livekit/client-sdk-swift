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
import LiveKitWebRTC
import Testing

@Suite(.tags(.dataChannel, .e2ee))
struct PlaintextDataChannelTests {
    enum Payload: CaseIterable {
        case user, chatMessage, rpcRequest, rpcResponse, rpcAck, streamHeader, streamChunk, streamTrailer

        var hasAppCallback: Bool { self == .user || self == .rpcRequest || self == .streamHeader }

        var packet: Livekit_DataPacket {
            .with {
                $0.participantIdentity = "sender"
                switch self {
                case .user:
                    $0.user = .with { $0.payload = Data("hello".utf8) }
                case .chatMessage:
                    $0.chatMessage = .with { $0.message = "hello" }
                case .rpcRequest:
                    $0.rpcRequest = .with {
                        $0.id = "request"
                        $0.method = "hello"
                        $0.payload = "hello"
                        $0.version = 1
                        $0.responseTimeoutMs = 1000
                    }
                case .rpcResponse:
                    $0.rpcResponse = .with { $0.requestID = "request"; $0.payload = "hello" }
                case .rpcAck:
                    $0.rpcAck = .with { $0.requestID = "request" }
                case .streamHeader:
                    $0.streamHeader = .with {
                        $0.streamID = "stream"
                        $0.topic = "hello"
                        $0.mimeType = "text/plain"
                        $0.textHeader = .with { _ in }
                    }
                case .streamChunk:
                    $0.streamChunk = .with { $0.streamID = "stream"; $0.content = Data("hello".utf8) }
                case .streamTrailer:
                    $0.streamTrailer = .with { $0.streamID = "stream" }
                }
            }
        }
    }

    enum Reception: CaseIterable {
        case plaintextEncryptedRoom, plaintextDisabledRoom, plaintextUnconfiguredRoom
        case encryptedRoom, encryptedDisabledRoom, wrongKey, deliverPolicy

        var encrypted: Bool { self == .encryptedRoom || self == .encryptedDisabledRoom || self == .wrongKey }
        var enabled: Bool { self != .plaintextDisabledRoom && self != .encryptedDisabledRoom }
        var delivered: Bool { self != .plaintextEncryptedRoom && self != .wrongKey }
    }

    @Test(arguments: Payload.allCases, Reception.allCases)
    func receivePolicy(payload: Payload, reception: Reception) async throws {
        for reliable in [true, false] {
            let options = RoomOptions(encryptionOptions: reception == .plaintextUnconfiguredRoom ? nil : .sharedKey("test-key"))
            let context = try await ReceiveContext(options: options,
                                                   enabled: reception.enabled,
                                                   policy: reception == .deliverPolicy ? .deliver : .default)
            defer { context.cleanUp() }
            let packet = payload.packet
            let wirePacket: Livekit_DataPacket = if reception.encrypted {
                try context.encrypt(packet, wrongKey: reception == .wrongKey)
            } else {
                packet
            }
            try await context.receive(wirePacket, reliable: reliable)
            try await context.expectDelivery(packet,
                                             delivered: reception.delivered,
                                             encryptionType: reception.encrypted ? .gcm : .none,
                                             hasAppCallback: payload.hasAppCallback)
            #expect(context.observer.decryptionErrors == (reception == .wrongKey ? 1 : 0))
        }
    }

    @available(*, deprecated, message: "Covers the deprecated media-only E2EEOptions")
    @Test(arguments: Payload.allCases)
    func legacyMediaOnlyReceiverDeliversPlaintext(payload: Payload) async throws {
        let options = RoomOptions(e2eeOptions: E2EEOptions(keyProvider: BaseKeyProvider(isSharedKey: true, sharedKey: "test-key")))
        let context = try await ReceiveContext(options: options)
        defer { context.cleanUp() }
        #expect(context.room.e2eeManager?.isDataChannelEncryptionEnabled == false)
        try await context.receive(payload.packet, reliable: true)
        try await context.expectDelivery(payload.packet, delivered: true, encryptionType: .none, hasAppCallback: payload.hasAppCallback)
    }

    enum Control: CaseIterable {
        case speaker, sipDtmf, transcription, metrics, empty

        var packet: Livekit_DataPacket {
            .with {
                switch self {
                case .speaker: $0.speaker = .with { _ in }
                case .sipDtmf: $0.sipDtmf = .with { _ in }
                case .transcription: $0.transcription = .with { _ in }
                case .metrics: $0.metrics = .with { _ in }
                case .empty: break
                }
            }
        }
    }

    @Test(arguments: Control.allCases, [true, false])
    func controlPacketsRemainPlaintext(control: Control, enabled: Bool) async throws {
        for reliable in [true, false] {
            let context = try await ReceiveContext(enabled: enabled)
            defer { context.cleanUp() }
            #expect(Livekit_EncryptedPacketPayload(dataPacket: control.packet) == nil)
            try await context.receive(control.packet, reliable: reliable)
            try await context.expectDelivery(control.packet, delivered: true, encryptionType: .none, hasAppCallback: false)
            #expect(context.observer.decryptionErrors == 0)
        }
    }

    @Test(arguments: Payload.allCases)
    func droppedPlaintextCannotAdvanceReliableSequence(payload: Payload) async throws {
        let context = try await ReceiveContext()
        defer { context.cleanUp() }
        let plaintext = payload.packet.modifying { $0.participantSid = "PA_sender"; $0.sequence = 100 }
        try await context.receive(plaintext, reliable: true)
        #expect(context.pair.receiveStates().isEmpty)
        #expect(context.observer.packets.isEmpty)
        let packet = plaintext.modifying { $0.sequence = 1 }
        try await context.receive(context.encrypt(packet), reliable: true)
        try await context.expectDelivery(packet, delivered: true, encryptionType: .gcm, hasAppCallback: payload.hasAppCallback)
        #expect(context.pair.receiveStates().map(\.lastSeq) == [1])
    }
}

private struct ReceiveContext {
    let observer = ReceiveObserver()
    let room: Room
    var pair: DataChannelPair { room.subscriberDataChannel }

    init(options: RoomOptions = RoomOptions(encryptionOptions: .sharedKey("test-key")),
         enabled: Bool = true,
         policy: DataChannelPair.PlaintextReceivePolicy = .default) async throws
    {
        room = Room(delegate: observer, roomOptions: options)
        let connection = ConnectionDependencies(idle: room._state.stage.idle, room: room, roomOptions: options)
        try room._state.mutate {
            try $0.stage.begin(connection)
            $0.connectionState = .connected
        }
        if let manager = room.e2eeManager {
            manager.setup(room: room)
            manager.enableE2EE(enabled: enabled)
        }
        await room.rpcServer.attach(to: room)
        room.publisherDataChannel = MockDataChannelPair { _ in }
        let observer = observer
        try await room.registerRpcMethod("hello") { _ in
            observer.appCallback()
            return "hello"
        }
        try await room.registerTextStreamHandler(for: "hello") { _, _ in observer.appCallback() }
        room.subscriberDataChannel = DataChannelPair(delegate: room, plaintextReceivePolicy: policy)
        pair.set(e2eeManager: room.e2eeManager)
        pair.delegates.add(delegate: observer)
    }

    func cleanUp() {
        room.e2eeManager?.cleanUp()
        _ = room._state.mutate { $0.stage.end() }
    }

    func encrypt(_ packet: Livekit_DataPacket, wrongKey: Bool = false) throws -> Livekit_DataPacket {
        let payload = try #require(Livekit_EncryptedPacketPayload(dataPacket: packet))
        let keyProvider = BaseKeyProvider(isSharedKey: true, sharedKey: wrongKey ? "wrong-key" : "test-key")
        let cryptor = try #require(LKRTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: keyProvider.rtcKeyProvider))
        let encrypted = try Livekit_EncryptedPacket(rtcPacket: #require(cryptor.encrypt(packet.participantIdentity,
                                                                                        keyIndex: 0,
                                                                                        data: payload.serializedData())))
        return packet.modifying { $0.encryptedPacket = encrypted }
    }

    /// Exercise decoding and dispatch at the WebRTC delegate boundary without a server.
    @RTC private func inject(_ packet: Livekit_DataPacket, reliable: Bool) throws {
        let peer = try #require(RTC.createPeerConnection(LKRTCConfiguration.liveKitDefault(),
                                                         constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)))
        defer { peer.close() }
        let channel = try #require(peer.dataChannel(forLabel: reliable ? "_reliable" : "_lossy", configuration: RTC.createDataChannelConfiguration()))
        if reliable { pair.set(reliable: channel) } else { pair.set(lossy: channel) }
        defer {
            if reliable {
                pair.set(reliable: nil)
            } else {
                pair.set(lossy: nil)
            }
        }
        let delegate = try #require(channel.delegate)
        try delegate.dataChannel(channel, didReceiveMessageWith: RTC.createDataBuffer(data: packet.serializedData()))
    }

    func receive(_ packet: Livekit_DataPacket, reliable: Bool) async throws {
        try await inject(packet, reliable: reliable)
        // FIFO barriers make absence checks wait for dispatch without a timeout.
        await pair.delegates.notifyAsync { _ in }
        await room.delegates.notifyAsync { _ in }
    }

    func expectDelivery(_ packet: Livekit_DataPacket, delivered: Bool, encryptionType: EncryptionType, hasAppCallback: Bool) async throws {
        if hasAppCallback, delivered { try await observer.appEvent.wait() }
        #expect(observer.packets == (delivered ? [packet] : []))
        #expect(observer.encryptionTypes == (delivered ? [encryptionType] : []))
        #expect(observer.appCallbacks == (hasAppCallback && delivered ? 1 : 0))
    }
}

private final class ReceiveObserver: NSObject, DataChannelDelegate, RoomDelegate, Sendable {
    private struct State {
        var packets: [Livekit_DataPacket] = []
        var encryptionTypes: [EncryptionType] = []
        var decryptionErrors = 0
        var appCallbacks = 0
    }

    private let state = StateSync(State())
    let appEvent = AsyncCompleter<Void>(label: "App callback", defaultTimeout: 2)
    var appCallbacks: Int { state.appCallbacks }

    func appCallback() {
        state.mutate { $0.appCallbacks += 1 }
        appEvent.resume(returning: ())
    }

    var packets: [Livekit_DataPacket] { state.packets }
    var encryptionTypes: [EncryptionType] { state.encryptionTypes }
    var decryptionErrors: Int { state.decryptionErrors }

    func dataChannel(_: DataChannelPair, didReceiveDataPacket packet: Livekit_DataPacket, serialized _: Data?, encryptionType: EncryptionType) {
        state.mutate {
            $0.packets.append(packet)
            $0.encryptionTypes.append(encryptionType)
        }
    }

    func dataChannel(_: DataChannelPair, didFailToDecryptDataPacket _: Livekit_DataPacket, error _: LiveKitError) {
        state.mutate { $0.decryptionErrors += 1 }
    }

    func room(_: Room, participant _: RemoteParticipant?, didReceiveData _: Data, forTopic _: String, encryptionType _: EncryptionType) {
        appCallback()
    }
}
