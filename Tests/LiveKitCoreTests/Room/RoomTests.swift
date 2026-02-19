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

@Suite(.serialized) final class RoomTests: @unchecked Sendable {
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
        // Capture weak references to all room sub-objects
        weak var weakSignalClient: SignalClient?
        weak var weakSocket: WebSocket?
        weak var weakPublisher: Transport?
        weak var weakSubscriber: Transport?
        weak var weakPublisherDataChannel: DataChannelPair?
        weak var weakSubscriberDataChannel: DataChannelPair?
        weak var weakIncomingStreamManager: IncomingStreamManager?
        weak var weakOutgoingStreamManager: OutgoingStreamManager?
        weak var weakE2eeManager: E2EEManager?
        weak var weakPreConnectBuffer: PreConnectAudioBuffer?
        weak var weakRpcState: RpcStateManager?
        weak var weakMetricsManager: MetricsManager?
        weak var weakDelegates: MulticastDelegate<RoomDelegate>?
        weak var weakActiveParticipantCompleters: CompleterMapActor<Void>?
        weak var weakPrimaryTransportConnectedCompleter: AsyncCompleter<Void>?
        weak var weakPublisherTransportConnectedCompleter: AsyncCompleter<Void>?
        weak var weakLocalParticipant: LocalParticipant?
        // Store weak refs for remote participants as an array of closures that check nil
        var remoteParticipantChecks: [() -> Bool] = []
        weak var weakState: StateSync<Room.State>?
        weak var weakRoom: Room?

        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]

            weakSignalClient = room.signalClient
            weakSocket = await room.signalClient._state.socket

            let (publisher, subscriber) = room._state.read { ($0.publisher, $0.subscriber) }
            weakPublisher = publisher
            weakSubscriber = subscriber

            weakPublisherDataChannel = room.publisherDataChannel
            weakSubscriberDataChannel = room.subscriberDataChannel

            weakIncomingStreamManager = room.incomingStreamManager
            weakOutgoingStreamManager = room.outgoingStreamManager

            if let e2eeManager = room.e2eeManager { weakE2eeManager = e2eeManager }
            weakPreConnectBuffer = room.preConnectBuffer
            weakRpcState = room.rpcState
            weakMetricsManager = room.metricsManager

            weakDelegates = room.delegates
            weakActiveParticipantCompleters = room.activeParticipantCompleters
            weakPrimaryTransportConnectedCompleter = room.primaryTransportConnectedCompleter
            weakPublisherTransportConnectedCompleter = room.publisherTransportConnectedCompleter

            weakLocalParticipant = room.localParticipant
            for remoteParticipant in room.remoteParticipants.values {
                weak var weakRP: RemoteParticipant? = remoteParticipant
                remoteParticipantChecks.append { weakRP == nil }
            }

            weakState = room._state
            weakRoom = room
        }

        // Allow time for deallocation after withRooms returns (rooms disconnected)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        #expect(weakSignalClient == nil, "Leaked object: SignalClient")
        #expect(weakSocket == nil, "Leaked object: WebSocket")
        #expect(weakPublisher == nil, "Leaked object: Publisher Transport")
        #expect(weakSubscriber == nil, "Leaked object: Subscriber Transport")
        #expect(weakPublisherDataChannel == nil, "Leaked object: Publisher DataChannel")
        #expect(weakSubscriberDataChannel == nil, "Leaked object: Subscriber DataChannel")
        #expect(weakIncomingStreamManager == nil, "Leaked object: IncomingStreamManager")
        #expect(weakOutgoingStreamManager == nil, "Leaked object: OutgoingStreamManager")
        #expect(weakE2eeManager == nil, "Leaked object: E2EEManager")
        #expect(weakPreConnectBuffer == nil, "Leaked object: PreConnectBuffer")
        #expect(weakRpcState == nil, "Leaked object: RpcState")
        #expect(weakMetricsManager == nil, "Leaked object: MetricsManager")
        #expect(weakDelegates == nil, "Leaked object: Delegates")
        #expect(weakActiveParticipantCompleters == nil, "Leaked object: ActiveParticipantCompleters")
        #expect(weakPrimaryTransportConnectedCompleter == nil, "Leaked object: PrimaryTransportConnectedCompleter")
        #expect(weakPublisherTransportConnectedCompleter == nil, "Leaked object: PublisherTransportConnectedCompleter")
        #expect(weakLocalParticipant == nil, "Leaked object: LocalParticipant")
        for check in remoteParticipantChecks {
            #expect(check(), "Leaked object: RemoteParticipant")
        }
        #expect(weakState == nil, "Leaked object: Room.State")
        #expect(weakRoom == nil, "Leaked object: Room")
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

extension RoomTests: RoomDelegate {
    func room(_: Room, participantDidDisconnect participant: RemoteParticipant) {
        print("participantDidDisconnect: \(participant)")
        // Check issue: https://github.com/livekit/client-sdk-swift/issues/300
        // participant.identity is null in participantDidDisconnect delegate
        #expect(participant.identity != nil, "participant.identity is nil in participantDidDisconnect delegate")
    }
}
