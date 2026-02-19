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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.serialized, .tags(.e2e)) final class RoomTests: @unchecked Sendable {
    @Test func roomProperties() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            // Alias to Room
            let room1 = rooms[0]

            // SID
            let sid = try await room1.sid()
            print("Room.sid(): \(String(describing: sid))")
            #expect(sid.stringValue.starts(with: "RM_"))

            // creationTime
            #expect(room1.creationTime != nil)
            print("Room.creationTime: \(String(describing: room1.creationTime))")
        }
    }

    @Test func participantCleanUp() async throws {
        // Create 2 Rooms
        try await TestEnvironment.withRooms([RoomTestingOptions(delegate: self), RoomTestingOptions(delegate: self)]) { _ in
            // Nothing to do here
        }
    }

    @Test func resourcesCleanUp() async throws {
        var refs = WeakRoomRefs()

        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            await refs.capture(from: rooms[0])
        }

        // Allow time for deallocation after withRooms returns (rooms disconnected)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        refs.expectAllNil()
    }

    @Test func sendDataPacket() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]

            try await confirmation("Should send data packet") { confirm in
                let mockDataChannel = MockDataChannelPair { packet in
                    #expect(packet.participantIdentity == room.localParticipant.identity?.stringValue ?? "")
                    confirm()
                }
                room.publisherDataChannel = mockDataChannel

                try await room.send(dataPacket: Livekit_DataPacket())

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}

private struct WeakRoomRefs: @unchecked Sendable {
    weak var signalClient: SignalClient?
    weak var socket: WebSocket?
    weak var publisher: Transport?
    weak var subscriber: Transport?
    weak var publisherDataChannel: DataChannelPair?
    weak var subscriberDataChannel: DataChannelPair?
    weak var incomingStreamManager: IncomingStreamManager?
    weak var outgoingStreamManager: OutgoingStreamManager?
    weak var e2eeManager: E2EEManager?
    weak var preConnectBuffer: PreConnectAudioBuffer?
    weak var rpcState: RpcStateManager?
    weak var metricsManager: MetricsManager?
    weak var delegates: MulticastDelegate<RoomDelegate>?
    weak var activeParticipantCompleters: CompleterMapActor<Void>?
    weak var primaryTransportConnectedCompleter: AsyncCompleter<Void>?
    weak var publisherTransportConnectedCompleter: AsyncCompleter<Void>?
    weak var localParticipant: LocalParticipant?
    var remoteParticipantChecks: [() -> Bool] = []
    weak var state: StateSync<Room.State>?
    weak var room: Room?

    mutating func capture(from room: Room) async {
        signalClient = room.signalClient
        socket = await room.signalClient._state.socket

        let transports = room._state.read { ($0.publisher, $0.subscriber) }
        publisher = transports.0
        subscriber = transports.1

        publisherDataChannel = room.publisherDataChannel
        subscriberDataChannel = room.subscriberDataChannel
        incomingStreamManager = room.incomingStreamManager
        outgoingStreamManager = room.outgoingStreamManager
        if let mgr = room.e2eeManager { e2eeManager = mgr }
        preConnectBuffer = room.preConnectBuffer
        rpcState = room.rpcState
        metricsManager = room.metricsManager
        delegates = room.delegates
        activeParticipantCompleters = room.activeParticipantCompleters
        primaryTransportConnectedCompleter = room.primaryTransportConnectedCompleter
        publisherTransportConnectedCompleter = room.publisherTransportConnectedCompleter
        localParticipant = room.localParticipant

        for remoteParticipant in room.remoteParticipants.values {
            weak var weakRP: RemoteParticipant? = remoteParticipant
            remoteParticipantChecks.append { weakRP == nil }
        }

        state = room._state
        self.room = room
    }

    func expectAllNil() {
        #expect(signalClient == nil, "Leaked object: SignalClient")
        #expect(socket == nil, "Leaked object: WebSocket")
        #expect(publisher == nil, "Leaked object: Publisher Transport")
        #expect(subscriber == nil, "Leaked object: Subscriber Transport")
        #expect(publisherDataChannel == nil, "Leaked object: Publisher DataChannel")
        #expect(subscriberDataChannel == nil, "Leaked object: Subscriber DataChannel")
        #expect(incomingStreamManager == nil, "Leaked object: IncomingStreamManager")
        #expect(outgoingStreamManager == nil, "Leaked object: OutgoingStreamManager")
        #expect(e2eeManager == nil, "Leaked object: E2EEManager")
        #expect(preConnectBuffer == nil, "Leaked object: PreConnectBuffer")
        #expect(rpcState == nil, "Leaked object: RpcState")
        #expect(metricsManager == nil, "Leaked object: MetricsManager")
        #expect(delegates == nil, "Leaked object: Delegates")
        #expect(activeParticipantCompleters == nil, "Leaked object: ActiveParticipantCompleters")
        #expect(primaryTransportConnectedCompleter == nil, "Leaked object: PrimaryTransportConnectedCompleter")
        #expect(publisherTransportConnectedCompleter == nil, "Leaked object: PublisherTransportConnectedCompleter")
        #expect(localParticipant == nil, "Leaked object: LocalParticipant")
        for check in remoteParticipantChecks {
            #expect(check(), "Leaked object: RemoteParticipant")
        }
        #expect(state == nil, "Leaked object: Room.State")
        #expect(room == nil, "Leaked object: Room")
    }
}

extension RoomTests: RoomDelegate {
    func room(_: Room, participantDidDisconnect participant: RemoteParticipant) {
        print("participantDidDisconnect: \(participant)")
        // Check issue: https://github.com/livekit/client-sdk-swift/issues/300
        // participant.identity is null in participantDidDisconnect delegate
        #expect(participant.identity != nil, "participant.identity is nil in participantDidDisconnect delegate")
    }
}
