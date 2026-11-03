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

struct RoomParticipantUpdatesTests {
    enum Delivery: CaseIterable {
        case rejoin, separateUpdates, disconnectFirst, disconnectLast
    }

    @Test(.bug("https://github.com/livekit/client-sdk-js/issues/2228"), arguments: Delivery.allCases)
    func staleDisconnectRetainsNewSession(delivery: Delivery) async throws {
        let events = ParticipantUpdateEvents()
        let room = makeRoom(delegate: events)
        await update(room, [info(sid: "PA_old")])
        let participant = try #require(room.remoteParticipants[identity])
        let publication = try #require(participant.trackPublications[trackSid])
        let active = info(sid: "PA_new")
        let disconnected = info(sid: "PA_old", state: .disconnected)

        switch delivery {
        case .rejoin:
            await update(room, [disconnected])
            await update(room, [active])
            await update(room, [disconnected])
        case .separateUpdates:
            await update(room, [active])
            await update(room, [disconnected])
        case .disconnectFirst:
            await update(room, [disconnected, active])
        case .disconnectLast:
            await update(room, [active, disconnected])
        }
        await room.delegates.notifyAsync { _ in }

        let current = try #require(room.remoteParticipants[identity])
        #expect(current.sid == Participant.Sid(from: "PA_new"))
        let replaced = delivery == .rejoin || delivery == .disconnectFirst
        #expect((current === participant) == !replaced)
        #expect((current.trackPublications[trackSid] === publication) == !replaced)
        #expect(current.trackPublications[trackSid] != nil)
        #expect(events.lifecycle.copy() == (replaced
                ? ["connect:PA_old", "disconnect:PA_old", "connect:PA_new"]
                : ["connect:PA_old"]))
        #expect(events.unpublished.copy() == (replaced ? [trackSid] : []))
    }

    @Test(arguments: [("PA_new", "PA_new"), ("PA_new", ""), ("", "PA_new"), ("", "")])
    func matchingOrEmptySidDisconnectCleansUpOnce(currentSid: String, disconnectedSid: String) async throws {
        let events = ParticipantUpdateEvents()
        let room = makeRoom(delegate: events)
        await update(room, [info(sid: currentSid)])
        let participant = try #require(room.remoteParticipants[identity])
        let disconnected = info(sid: disconnectedSid, state: .disconnected)

        await update(room, [disconnected, disconnected])
        await update(room, [disconnected])
        await room.delegates.notifyAsync { _ in }

        #expect(room.remoteParticipants.isEmpty)
        #expect(participant.trackPublications.isEmpty)
        #expect(events.lifecycle.copy() == ["connect:\(currentSid)", "disconnect:\(currentSid)"])
        #expect(events.unpublished.copy() == [trackSid])
    }

    @Test func staleDisconnectPreservesRpcAndStream() async throws {
        let room = makeRoom()
        let connection = ConnectionDependencies(idle: room._state.stage.idle, room: room, roomOptions: RoomOptions())
        try room._state.mutate { try $0.stage.begin(connection) }
        await update(room, [info(sid: "PA_new")])
        let opened = AsyncCompleter<TextStreamReader>(label: "Stream opened", defaultTimeout: 5)
        try room.dataStreams.registerTextStreamHandler(for: "test") { reader, _ in
            opened.resume(returning: reader)
        }
        room.dataStreams.handleIncoming(.with {
            $0.participantIdentity = identity.stringValue
            $0.streamHeader = .with {
                $0.streamID = "stream"
                $0.topic = "test"
                $0.textHeader = .with { _ in }
            }
        }, serialized: nil, encryptionType: .none)
        let reader = try await opened.wait()
        let deadline = Date().addingTimeInterval(5)
        while await room.dataStreams.openStreamCount() != 1, Date() < deadline {
            await Task.yield()
        }
        try #require(await room.dataStreams.openStreamCount() == 1)

        await room.rpcClient.attach(to: room)
        room.publisherDataChannel = MockDataChannelPair { _ in }
        await room.rpcClient.setAfterPublish { [weak room, self] requestId in
            guard let room else { return }
            let disconnected = info(sid: "PA_old", state: .disconnected)
            await update(room, [disconnected, disconnected])
            #expect(await room.rpcClient.pendingCount == 1)
            await room.rpcClient.handleIncomingResponse(requestId: requestId, payload: "ok", error: nil)
        }
        defer { room.dataStreams.reset() }
        #expect(try await room.localParticipant.performRpc(destinationIdentity: identity, method: "test", payload: "") == "ok")
        room.dataStreams.handleIncoming(.with {
            $0.participantIdentity = identity.stringValue
            $0.streamTrailer = .with { $0.streamID = "stream" }
        }, serialized: nil, encryptionType: .none)
        #expect(try await reader.readAll() == "")
        await room.rpcClient.setAfterPublish(nil)
    }

    @Test func unknownDisconnectRejectsPendingRpc() async {
        let room = makeRoom()
        await room.rpcClient.attach(to: room)
        room.publisherDataChannel = MockDataChannelPair { _ in }
        await room.rpcClient.setAfterPublish { [weak room, self] _ in
            guard let room else { return }
            await update(room, [info(sid: "PA_unknown", state: .disconnected)])
        }
        await #expect {
            try await room.localParticipant.performRpc(destinationIdentity: identity, method: "test", payload: "")
        } throws: {
            ($0 as? RpcError)?.code == RpcError.BuiltInError.recipientDisconnected.code
        }
        #expect(await room.rpcClient.pendingCount == 0)
        await room.rpcClient.setAfterPublish(nil)
    }

    @Test func roomMoveReplacesParticipants() async throws {
        let events = ParticipantUpdateEvents()
        let room = makeRoom(delegate: events)
        await update(room, [info(sid: "PA_old")])
        let old = try #require(room.remoteParticipants[identity])
        await room.signalClient(room.signalClient, didReceiveRoomMoved: .with {
            $0.otherParticipants = [info(sid: "PA_new")]
        })
        await room.delegates.notifyAsync { _ in }

        let current = try #require(room.remoteParticipants[identity])
        #expect(current !== old)
        #expect(current.sid == Participant.Sid(from: "PA_new"))
        #expect(events.lifecycle.copy() == ["connect:PA_old", "disconnect:PA_old", "connect:PA_new"])
        #expect(events.unpublished.copy() == [trackSid])
    }

    private let identity = Participant.Identity(from: "remote")
    private let trackSid = Track.Sid(from: "TR_test")

    private func makeRoom(delegate: ParticipantUpdateEvents? = nil) -> Room {
        let room = Room(delegate: delegate)
        room._state.onDidMutate = nil
        _ = room.localParticipant
        room._state.mutate { $0.connectionState = .connected }
        return room
    }

    private func update(_ room: Room, _ participants: [Livekit_ParticipantInfo]) async {
        await room.signalClient(room.signalClient, didUpdateParticipants: participants)
        await room.delegates.notifyAsync { _ in }
    }

    private func info(sid: String, state: Livekit_ParticipantInfo_State = .active) -> Livekit_ParticipantInfo {
        .with {
            $0.identity = identity.stringValue
            $0.sid = sid
            $0.state = state
            $0.tracks = [.with {
                $0.sid = trackSid.stringValue
                $0.type = .audio
            }]
        }
    }
}

private final class ParticipantUpdateEvents: RoomDelegate, Sendable {
    let lifecycle = StateSync([String]())
    let unpublished = StateSync([Track.Sid]())

    func room(_: Room, participantDidConnect participant: RemoteParticipant) {
        lifecycle.mutate { $0.append("connect:\(participant.sid?.stringValue ?? "")") }
    }

    func room(_: Room, participantDidDisconnect participant: RemoteParticipant) {
        lifecycle.mutate { $0.append("disconnect:\(participant.sid?.stringValue ?? "")") }
    }

    func room(_: Room, participant _: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        unpublished.mutate { $0.append(publication.sid) }
    }
}
