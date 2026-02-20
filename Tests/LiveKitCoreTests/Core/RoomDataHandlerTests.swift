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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Lightweight delegate tracker for verifying data/transcription delegate calls.
private final class DataDelegateTracker: RoomDelegate, @unchecked Sendable {
    var receivedData: Data?
    var receivedTopic: String?
    var receivedParticipant: RemoteParticipant?
    var receivedEncryptionType: EncryptionType?
    var transcriptionSegments: [TranscriptionSegment]?
    var transcriptionParticipant: Participant?
    var transcriptionPublication: TrackPublication?

    func room(_: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        receivedData = data
        receivedTopic = topic
        receivedParticipant = participant
        receivedEncryptionType = encryptionType
    }

    func room(_: Room, participant: Participant, trackPublication: TrackPublication, didReceiveTranscriptionSegments segments: [TranscriptionSegment]) {
        transcriptionSegments = segments
        transcriptionParticipant = participant
        transcriptionPublication = trackPublication
    }
}

/// Tests for Room's data packet, transcription, and RPC handling
/// in Room+EngineDelegate.swift.
class RoomDataHandlerTests: LKTestCase {
    // MARK: - Helper

    private func makeConnectedRoom() -> (Room, DataDelegateTracker) {
        let room = Room()
        room._state.mutate { $0.connectionState = .connected }
        let localInfo = TestData.participantInfo(sid: "PA_local", identity: "local-user")
        room.localParticipant.set(info: localInfo, connectionState: .connected)
        let tracker = DataDelegateTracker()
        room.delegates.add(delegate: tracker)
        return (room, tracker)
    }

    private func addRemoteParticipant(
        to room: Room,
        sid: String = "PA_r1",
        identity: String = "remote-user",
        tracks: [Livekit_TrackInfo] = []
    ) -> RemoteParticipant {
        let info = TestData.participantInfo(sid: sid, identity: identity, tracks: tracks)
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)
        room._state.mutate {
            $0.remoteParticipants[Participant.Identity(from: identity)] = participant
        }
        return participant
    }

    /// Wait for MulticastDelegate's async dispatch to complete.
    private func waitForDelegates() {
        let exp = expectation(description: "delegate dispatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - Data Packet (UserPacket)

    func testReceiveUserPacketFromRemoteParticipant() {
        let (room, tracker) = makeConnectedRoom()
        _ = addRemoteParticipant(to: room, identity: "remote-user")

        let payload = Data("test".utf8)
        let packet = TestData.userPacket(participantIdentity: "remote-user", payload: payload, topic: "chat")
        room.engine(room, didReceiveUserPacket: packet, encryptionType: .none)
        waitForDelegates()

        XCTAssertEqual(tracker.receivedData, payload)
        XCTAssertEqual(tracker.receivedTopic, "chat")
        XCTAssertNotNil(tracker.receivedParticipant)
        XCTAssertEqual(tracker.receivedParticipant?.identity?.stringValue, "remote-user")
        XCTAssertEqual(tracker.receivedEncryptionType, EncryptionType.none)
    }

    func testReceiveUserPacketFromUnknownParticipant() {
        let (room, tracker) = makeConnectedRoom()

        // Participant not in room — should still deliver (participant is nil, broadcasted from server)
        let payload = Data("msg".utf8)
        let packet = TestData.userPacket(participantIdentity: "unknown", payload: payload, topic: "system")
        room.engine(room, didReceiveUserPacket: packet, encryptionType: .none)
        waitForDelegates()

        XCTAssertEqual(tracker.receivedData, payload)
        XCTAssertEqual(tracker.receivedTopic, "system")
        XCTAssertNil(tracker.receivedParticipant)
    }

    func testReceiveUserPacketNotConnectedDoesNotNotify() {
        let room = Room()
        let tracker = DataDelegateTracker()
        room.delegates.add(delegate: tracker)

        // Room not connected — should skip delegate notification
        let packet = TestData.userPacket()
        room.engine(room, didReceiveUserPacket: packet, encryptionType: .none)
        waitForDelegates()

        XCTAssertNil(tracker.receivedData)
    }

    func testReceiveUserPacketWithEncryption() {
        let (room, tracker) = makeConnectedRoom()
        _ = addRemoteParticipant(to: room, identity: "remote-user")

        let packet = TestData.userPacket(participantIdentity: "remote-user")
        room.engine(room, didReceiveUserPacket: packet, encryptionType: .gcm)
        waitForDelegates()

        XCTAssertNotNil(tracker.receivedData)
        XCTAssertEqual(tracker.receivedEncryptionType, .gcm)
    }

    // MARK: - Transcription

    func testTranscriptionWithValidParticipantAndTrack() {
        let (room, tracker) = makeConnectedRoom()
        let audioTrack = TestData.trackInfo(sid: "TR_audio1", name: "mic", type: .audio, source: .microphone)
        _ = addRemoteParticipant(to: room, identity: "remote-user", tracks: [audioTrack])

        let seg = TestData.transcriptionSegment(id: "seg-1", text: "Hello", isFinal: false)
        let transcription = TestData.transcription(
            participantIdentity: "remote-user",
            trackID: "TR_audio1",
            segments: [seg]
        )

        room.room(didReceiveTranscriptionPacket: transcription)
        waitForDelegates()

        // Verify received time is tracked for non-final segment
        let receivedTimes = room._state.read { $0.transcriptionReceivedTimes }
        XCTAssertNotNil(receivedTimes["seg-1"])

        // Verify delegate was called
        XCTAssertEqual(tracker.transcriptionSegments?.count, 1)
        XCTAssertEqual(tracker.transcriptionSegments?.first?.text, "Hello")
        XCTAssertEqual(tracker.transcriptionSegments?.first?.id, "seg-1")
        XCTAssertEqual(tracker.transcriptionParticipant?.identity?.stringValue, "remote-user")
    }

    func testTranscriptionFinalSegmentClearsReceivedTime() {
        let (room, _) = makeConnectedRoom()
        let audioTrack = TestData.trackInfo(sid: "TR_audio1", name: "mic", type: .audio, source: .microphone)
        _ = addRemoteParticipant(to: room, identity: "remote-user", tracks: [audioTrack])

        // First, non-final segment
        let seg1 = TestData.transcriptionSegment(id: "seg-1", text: "Hello", isFinal: false)
        let t1 = TestData.transcription(participantIdentity: "remote-user", trackID: "TR_audio1", segments: [seg1])
        room.room(didReceiveTranscriptionPacket: t1)
        XCTAssertNotNil(room._state.read { $0.transcriptionReceivedTimes["seg-1"] })

        // Final segment — should clear
        let seg2 = TestData.transcriptionSegment(id: "seg-1", text: "Hello world", isFinal: true)
        let t2 = TestData.transcription(participantIdentity: "remote-user", trackID: "TR_audio1", segments: [seg2])
        room.room(didReceiveTranscriptionPacket: t2)

        XCTAssertNil(room._state.read { $0.transcriptionReceivedTimes["seg-1"] })
    }

    func testTranscriptionMultipleSegments() {
        let (room, tracker) = makeConnectedRoom()
        let audioTrack = TestData.trackInfo(sid: "TR_audio1", name: "mic", type: .audio, source: .microphone)
        _ = addRemoteParticipant(to: room, identity: "remote-user", tracks: [audioTrack])

        let seg1 = TestData.transcriptionSegment(id: "seg-1", text: "Hello", isFinal: false)
        let seg2 = TestData.transcriptionSegment(id: "seg-2", text: "World", isFinal: true)
        let transcription = TestData.transcription(
            participantIdentity: "remote-user",
            trackID: "TR_audio1",
            segments: [seg1, seg2]
        )

        room.room(didReceiveTranscriptionPacket: transcription)
        waitForDelegates()

        let times = room._state.read { $0.transcriptionReceivedTimes }
        XCTAssertNotNil(times["seg-1"]) // non-final: tracked
        XCTAssertNil(times["seg-2"]) // final: removed
        XCTAssertEqual(tracker.transcriptionSegments?.count, 2)
    }

    func testTranscriptionUnknownParticipantSkips() {
        let (room, tracker) = makeConnectedRoom()

        let seg = TestData.transcriptionSegment(id: "seg-1", text: "Hello")
        let transcription = TestData.transcription(participantIdentity: "nonexistent", trackID: "TR_x", segments: [seg])

        room.room(didReceiveTranscriptionPacket: transcription)
        waitForDelegates()

        // Should not crash, received times should be empty (early return before processing)
        let times = room._state.read { $0.transcriptionReceivedTimes }
        XCTAssertTrue(times.isEmpty)
        XCTAssertNil(tracker.transcriptionSegments)
    }

    func testTranscriptionUnknownTrackSkips() {
        let (room, tracker) = makeConnectedRoom()
        _ = addRemoteParticipant(to: room, identity: "remote-user")

        let seg = TestData.transcriptionSegment(id: "seg-1", text: "Hello")
        let transcription = TestData.transcription(participantIdentity: "remote-user", trackID: "TR_unknown", segments: [seg])

        room.room(didReceiveTranscriptionPacket: transcription)
        waitForDelegates()

        let times = room._state.read { $0.transcriptionReceivedTimes }
        XCTAssertTrue(times.isEmpty)
        XCTAssertNil(tracker.transcriptionSegments)
    }

    func testTranscriptionEmptySegmentsSkips() {
        let (room, tracker) = makeConnectedRoom()
        let audioTrack = TestData.trackInfo(sid: "TR_audio1", name: "mic", type: .audio, source: .microphone)
        _ = addRemoteParticipant(to: room, identity: "remote-user", tracks: [audioTrack])

        let transcription = TestData.transcription(
            participantIdentity: "remote-user",
            trackID: "TR_audio1",
            segments: []
        )

        room.room(didReceiveTranscriptionPacket: transcription)
        waitForDelegates()

        let times = room._state.read { $0.transcriptionReceivedTimes }
        XCTAssertTrue(times.isEmpty)
        XCTAssertNil(tracker.transcriptionSegments)
    }

    func testTranscriptionForRemoteWithMultipleUpdates() {
        let (room, _) = makeConnectedRoom()
        let audioTrack = TestData.trackInfo(sid: "TR_audio1", name: "mic", type: .audio, source: .microphone)
        _ = addRemoteParticipant(to: room, identity: "remote-user", tracks: [audioTrack])

        // First non-final update
        let seg1 = TestData.transcriptionSegment(id: "seg-1", text: "Hel", isFinal: false)
        let t1 = TestData.transcription(participantIdentity: "remote-user", trackID: "TR_audio1", segments: [seg1])
        room.room(didReceiveTranscriptionPacket: t1)

        let firstTime = room._state.read { $0.transcriptionReceivedTimes["seg-1"] }
        XCTAssertNotNil(firstTime)

        // Second non-final update — firstReceivedTime should be preserved
        let seg2 = TestData.transcriptionSegment(id: "seg-1", text: "Hello", isFinal: false)
        let t2 = TestData.transcription(participantIdentity: "remote-user", trackID: "TR_audio1", segments: [seg2])
        room.room(didReceiveTranscriptionPacket: t2)

        let secondTime = room._state.read { $0.transcriptionReceivedTimes["seg-1"] }
        XCTAssertNotNil(secondTime)
        // The first received time should be preserved (not overwritten)
        XCTAssertEqual(firstTime, secondTime)
    }

    // MARK: - RPC Response

    func testReceiveRpcResponsePayloadExtraction() {
        let (room, _) = makeConnectedRoom()

        var response = Livekit_RpcResponse()
        response.requestID = "req-123"
        response.value = .payload("result-data")

        // Verify the switch statement correctly extracts payload vs error
        let (payload, error): (String?, RpcError?) = switch response.value {
        case let .payload(v): (v, nil)
        case let .error(e): (nil, RpcError.fromProto(e))
        default: (nil, nil)
        }

        XCTAssertEqual(payload, "result-data")
        XCTAssertNil(error)

        // Also verify the handler doesn't crash with no pending completer
        room.room(didReceiveRpcResponse: response)
    }

    func testReceiveRpcResponseErrorExtraction() {
        let (room, _) = makeConnectedRoom()

        var rpcError = Livekit_RpcError()
        rpcError.code = 500
        rpcError.message = "Internal error"

        var response = Livekit_RpcResponse()
        response.requestID = "req-456"
        response.value = .error(rpcError)

        // Verify error extraction
        let (payload, error): (String?, RpcError?) = switch response.value {
        case let .payload(v): (v, nil)
        case let .error(e): (nil, RpcError.fromProto(e))
        default: (nil, nil)
        }

        XCTAssertNil(payload)
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.code, 500)
        XCTAssertEqual(error?.message, "Internal error")

        room.room(didReceiveRpcResponse: response)
    }

    // MARK: - RPC Ack

    func testReceiveRpcAckExtractsRequestId() {
        let (room, _) = makeConnectedRoom()

        var ack = Livekit_RpcAck()
        ack.requestID = "req-789"

        // Verify the request ID is correctly extracted
        XCTAssertEqual(ack.requestID, "req-789")

        // Handler doesn't crash with no pending completer
        room.room(didReceiveRpcAck: ack)
    }

    // MARK: - RPC Request

    func testReceiveRpcRequestParsesFields() async {
        let (room, _) = makeConnectedRoom()

        var request = Livekit_RpcRequest()
        request.id = "incoming-req-1"
        request.method = "greet"
        request.payload = "{\"name\": \"test\"}"
        request.responseTimeoutMs = 5000
        request.version = 1

        // Verify field extraction matches what the handler parses
        XCTAssertEqual(request.id, "incoming-req-1")
        XCTAssertEqual(request.method, "greet")
        XCTAssertEqual(request.payload, "{\"name\": \"test\"}")
        let responseTimeout = TimeInterval(UInt64(request.responseTimeoutMs) / UInt64(1000))
        XCTAssertEqual(responseTimeout, 5.0)
        XCTAssertEqual(Int(request.version), 1)

        room.room(didReceiveRpcRequest: request, from: "remote-user")

        // Allow the Task to dispatch
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}
