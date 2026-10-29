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

    /// Inject at the existing WebRTC delegate boundary, exercising decoding, the receive gate,
    /// and Room dispatch without changing product visibility or connecting to a server.
    @RTC private func receive(_ packet: Livekit_DataPacket, on pair: DataChannelPair) throws {
        let peer = try #require(RTC.createPeerConnection(LKRTCConfiguration.liveKitDefault(),
                                                         constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)))
        defer { peer.close() }
        let channel = try #require(peer.dataChannel(forLabel: "_reliable", configuration: RTC.createDataChannelConfiguration()))
        pair.set(reliable: channel)
        defer { pair.set(reliable: nil) }
        let delegate = try #require(channel.delegate)
        try delegate.dataChannel(channel, didReceiveMessageWith: RTC.createDataBuffer(data: packet.serializedData()))
    }

    @Test(arguments: Payload.allCases, [true, false])
    func plaintextReceivePolicy(payload: Payload, dataEncryptionEnabled: Bool) async throws {
        let observer = ReceiveObserver()
        let options = RoomOptions(encryptionOptions: .sharedKey("test-key"))
        let room = Room(delegate: observer, roomOptions: options)
        let connection = ConnectionDependencies(idle: room._state.stage.idle, room: room, roomOptions: options)
        try room._state.mutate {
            try $0.stage.begin(connection)
            $0.connectionState = .connected
        }
        let manager = try #require(room.e2eeManager)
        manager.setup(room: room)
        manager.enableE2EE(enabled: dataEncryptionEnabled)
        #expect(manager.isDataChannelEncryptionEnabled == dataEncryptionEnabled)
        await room.rpcServer.attach(to: room)
        room.publisherDataChannel = MockDataChannelPair { _ in }
        try await room.registerRpcMethod("hello") { _ in
            observer.appCallback()
            return "hello"
        }
        try await room.registerTextStreamHandler(for: "hello") { _, _ in observer.appCallback() }
        let pair = room.subscriberDataChannel
        pair.set(e2eeManager: manager)
        pair.delegates.add(delegate: observer)
        defer {
            manager.cleanUp()
            _ = room._state.mutate { $0.stage.end() }
        }

        try await receive(payload.packet, on: pair)
        // FIFO barriers drain both delegate queues: absence is checked after dispatch has run.
        await pair.delegates.notifyAsync { _ in }
        await room.delegates.notifyAsync { _ in }

        if payload.hasAppCallback, !observer.packets.isEmpty {
            try await observer.appEvent.wait()
        }
        #expect(observer.appCallbacks == (payload.hasAppCallback && !dataEncryptionEnabled ? 1 : 0))
        #expect(observer.packets.count == (dataEncryptionEnabled ? 0 : 1))
        #expect(observer.userData.count == (payload == .user && !dataEncryptionEnabled ? 1 : 0))
        #expect(observer.decryptionErrors == 0)
    }
}

private final class ReceiveObserver: NSObject, DataChannelDelegate, RoomDelegate, Sendable {
    private struct State {
        var packets: [Livekit_DataPacket] = []
        var userData: [Data] = []
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
    var userData: [Data] { state.userData }
    var decryptionErrors: Int { state.decryptionErrors }

    func dataChannel(_: DataChannelPair, didReceiveDataPacket packet: Livekit_DataPacket, serialized _: Data?, encryptionType _: EncryptionType) {
        state.mutate { $0.packets.append(packet) }
    }

    func dataChannel(_: DataChannelPair, didFailToDecryptDataPacket _: Livekit_DataPacket, error _: LiveKitError) {
        state.mutate { $0.decryptionErrors += 1 }
    }

    func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic _: String, encryptionType _: EncryptionType) {
        state.mutate { $0.userData.append(data) }
        appCallback()
    }
}
