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

// swiftlint:disable file_length

/// Peer Connection Signaling Tests
///
/// Ported from rust-sdks `peer_connection_signaling_test.rs`.
/// Tests verify that both V0 (dual PC) and V1 (single PC) signaling modes work correctly.
///
/// V0 (Dual PC): Traditional mode with separate publisher and subscriber peer connections.
/// V1 (Single PC): Single peer connection for both publish and subscribe.
///
/// V1 tests will fall back to V0 on localhost if the server doesn't support /rtc/v1.

import Combine
import CoreVideo
@testable import LiveKit
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

// MARK: - SignalingMode

enum SignalingMode: CustomStringConvertible {
    /// V0: Dual peer connection (/rtc path)
    case dualPC
    /// V1: Single peer connection (/rtc/v1 path)
    case singlePC

    var isSinglePeerConnection: Bool { self == .singlePC }

    var description: String {
        switch self {
        case .dualPC: "V0 (Dual PC)"
        case .singlePC: "V1 (Single PC)"
        }
    }
}

// MARK: - ReconnectWatcher

/// Watches for reconnect completion via RoomDelegate.
/// Uses didStartReconnectWithMode/didCompleteReconnectWithMode which fire for
/// BOTH quick and full reconnect (unlike roomDidReconnect which skips quick).
private final class ReconnectWatcher: NSObject, RoomDelegate, @unchecked Sendable {
    private struct State {
        var reconnectStartExpectation: XCTestExpectation?
        var reconnectCompleteExpectation: XCTestExpectation?
        var tracksRepublishedExpectation: XCTestExpectation?
        var expectedTrackCount: Int = 0
        var publishedTrackCount: Int = 0
        // Gate: only count didPublishTrack after reconnect completes.
        // All delegate callbacks flow through the same serial queue, so
        // the initial publish's didPublishTrack is guaranteed to fire
        // before didCompleteReconnectWithMode (enqueued earlier).
        var isCountingRepublishedTracks: Bool = false
    }

    private let _state = StateSync(State())

    func expectReconnect(description: String = "reconnect") -> (start: XCTestExpectation, complete: XCTestExpectation) {
        _state.mutate {
            let start = XCTestExpectation(description: "\(description) start")
            start.assertForOverFulfill = false
            let complete = XCTestExpectation(description: "\(description) complete")
            complete.assertForOverFulfill = false
            $0.reconnectStartExpectation = start
            $0.reconnectCompleteExpectation = complete
            return (start: start, complete: complete)
        }
    }

    func expectTracksRepublished(count: Int, description: String = "tracks republished") -> XCTestExpectation {
        _state.mutate {
            let expectation = XCTestExpectation(description: description)
            expectation.assertForOverFulfill = false
            $0.tracksRepublishedExpectation = expectation
            $0.expectedTrackCount = count
            $0.publishedTrackCount = 0
            $0.isCountingRepublishedTracks = false
            return expectation
        }
    }

    // MARK: - RoomDelegate

    func room(_: Room, didStartReconnectWithMode _: ReconnectMode) {
        _state.mutate { $0.reconnectStartExpectation?.fulfill() }
    }

    func room(_: Room, didCompleteReconnectWithMode _: ReconnectMode) {
        _state.mutate {
            $0.reconnectCompleteExpectation?.fulfill()
            $0.isCountingRepublishedTracks = true
        }
    }

    func room(_: Room, participant _: LocalParticipant, didPublishTrack _: LocalTrackPublication) {
        _state.mutate {
            guard $0.isCountingRepublishedTracks else { return }
            $0.publishedTrackCount += 1
            if $0.publishedTrackCount >= $0.expectedTrackCount {
                $0.tracksRepublishedExpectation?.fulfill()
            }
        }
    }
}

// MARK: - PeerConnectionSignalingTests

class PeerConnectionSignalingTests: LKTestCase {
    // MARK: - Helpers

    private func roomTestingOptions(
        mode: SignalingMode,
        delegate: RoomDelegate? = nil,
        canPublish: Bool = false,
        canPublishData: Bool = false,
        canSubscribe: Bool = false
    ) -> RoomTestingOptions {
        RoomTestingOptions(
            delegate: delegate,
            singlePeerConnection: mode.isSinglePeerConnection,
            canPublish: canPublish,
            canPublishData: canPublishData,
            canSubscribe: canSubscribe
        )
    }

    private func assertSignalingModeState(_ room: Room, mode: SignalingMode) {
        guard let transport = room._state.transport else {
            XCTFail("Transport is nil after connection")
            return
        }

        switch transport {
        case .publisherOnly:
            if mode == .dualPC {
                XCTFail("DualPC test should not have single-PC mode active")
            }
        case .subscriberPrimary, .publisherPrimary:
            if mode == .singlePC {
                let url = room.url ?? ""
                if url.contains("localhost") || url.contains("127.0.0.1") {
                    print("[\(mode)] SinglePC on localhost: fell back to dual PC (expected on older servers)")
                } else {
                    XCTFail("SinglePC requested on non-localhost URL should stay in single-PC mode")
                }
            }
        }
    }

    // MARK: - V0 (Dual PC) Tests

    func testV0Connect() async throws { try await _testConnect(mode: .dualPC) }
    func testV0TwoParticipants() async throws { try await _testTwoParticipants(mode: .dualPC) }
    func testV0AudioTrack() async throws { try await _testAudioTrack(mode: .dualPC) }
    func testV0Reconnect() async throws { try await _testReconnect(mode: .dualPC) }
    func testV0DataChannel() async throws { try await _testDataChannel(mode: .dualPC) }
    func testV0FullReconnect() async throws { try await _testFullReconnect(mode: .dualPC) }
    func testV0PublishManyTracks() async throws { try await _testPublishManyTracks(mode: .dualPC) }
    func testV0DoubleReconnect() async throws { try await _testDoubleReconnect(mode: .dualPC) }

    // MARK: - V1 (Single PC) Tests

    func testV1Connect() async throws { try await _testConnect(mode: .singlePC) }
    func testV1TwoParticipants() async throws { try await _testTwoParticipants(mode: .singlePC) }
    func testV1AudioTrack() async throws { try await _testAudioTrack(mode: .singlePC) }
    func testV1Reconnect() async throws { try await _testReconnect(mode: .singlePC) }
    func testV1DataChannel() async throws { try await _testDataChannel(mode: .singlePC) }
    func testV1FullReconnect() async throws { try await _testFullReconnect(mode: .singlePC) }
    func testV1PublishManyTracks() async throws { try await _testPublishManyTracks(mode: .singlePC) }
    func testV1DoubleReconnect() async throws { try await _testDoubleReconnect(mode: .singlePC) }

    func testV1LocalhostFallback() async throws {
        let url = liveKitServerUrl()
        guard url.contains("localhost") || url.contains("127.0.0.1") else {
            print("Skipping localhost fallback test because LIVEKIT_TESTING_URL override is set")
            return
        }

        try await withRooms([roomTestingOptions(mode: .singlePC, canPublish: true)]) { rooms in
            let room = rooms[0]
            XCTAssertEqual(room.connectionState, .connected)

            guard let transport = room._state.transport else {
                XCTFail("Transport is nil")
                return
            }

            switch transport {
            case .publisherOnly:
                print("Localhost server supports /rtc/v1 (single PC active)")
            case .subscriberPrimary, .publisherPrimary:
                print("Localhost server fell back to V0 as expected")
            }
        }
    }
}

// MARK: - Test Implementations

extension PeerConnectionSignalingTests {
    /// Test basic connection and verify transport mode.
    private func _testConnect(mode: SignalingMode) async throws {
        print("[\(mode)] Testing basic connection...")

        try await withRooms([roomTestingOptions(mode: mode, canPublish: true)]) { rooms in
            let room = rooms[0]

            XCTAssertEqual(room.connectionState, .connected)
            XCTAssertNotNil(room.localParticipant.identity, "LocalParticipant.identity should not be nil")
            self.assertSignalingModeState(room, mode: mode)

            print("[\(mode)] Connected! Room: \(room.name ?? "nil")")
            print("[\(mode)] Test passed - connection working!")
        }
    }

    /// Test two participants discovering each other.
    private func _testTwoParticipants(mode: SignalingMode) async throws {
        print("[\(mode)] Testing two participants...")

        try await withRooms([
            roomTestingOptions(mode: mode, canPublish: true, canSubscribe: true),
            roomTestingOptions(mode: mode, canPublish: true, canSubscribe: true),
        ]) { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            // withRooms already waits for participants to see each other
            XCTAssertEqual(room1.remoteParticipants.count, 1, "Room1 should see 1 remote participant")
            XCTAssertEqual(room2.remoteParticipants.count, 1, "Room2 should see 1 remote participant")

            self.assertSignalingModeState(room1, mode: mode)
            self.assertSignalingModeState(room2, mode: mode)

            print("[\(mode)] Test passed - two participants working!")
        }
    }

    private func _testAudioTrack(mode: SignalingMode) async throws {
        print("[\(mode)] Testing audio track...")

        try await withRooms([
            roomTestingOptions(mode: mode, canPublish: true),
            roomTestingOptions(mode: mode, canSubscribe: true),
        ]) { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            guard let publisherIdentity = room1.localParticipant.identity else {
                XCTFail("Publisher's identity is nil")
                return
            }

            guard let remoteParticipant = room2.remoteParticipants[publisherIdentity] else {
                XCTFail("Failed to lookup Publisher (RemoteParticipant)")
                return
            }

            // Watch for remote audio track subscription
            let didSubscribe = self.expectation(description: "Did subscribe to remote audio track")
            didSubscribe.assertForOverFulfill = false
            var remoteAudioTrack: RemoteAudioTrack?

            let watchParticipant = remoteParticipant.objectWillChange.sink { _ in
                if let track = remoteParticipant.firstAudioPublication?.track as? RemoteAudioTrack, remoteAudioTrack == nil {
                    remoteAudioTrack = track
                    didSubscribe.fulfill()
                }
            }

            // Publish audio via TestAudioTrack (bypasses AudioManager)
            let audioTrack = TestAudioTrack()
            try await room1.localParticipant.publish(audioTrack: audioTrack)

            print("[\(mode)] Waiting for remote audio track...")
            await self.fulfillment(of: [didSubscribe], timeout: 30)

            guard let remoteAudioTrack else {
                XCTFail("RemoteAudioTrack is nil")
                return
            }

            // Wait for actual audio frames
            let didReceiveFrame = self.expectation(description: "Did receive audio frame")
            didReceiveFrame.assertForOverFulfill = false

            let audioWatcher = AudioTrackWatcher(id: "audio-watcher") { _ in
                didReceiveFrame.fulfill()
            }
            remoteAudioTrack.add(audioRenderer: audioWatcher)

            print("[\(mode)] Waiting for audio frames...")
            await self.fulfillment(of: [didReceiveFrame], timeout: 30)

            remoteAudioTrack.remove(audioRenderer: audioWatcher)
            watchParticipant.cancel()

            print("[\(mode)] Test passed - audio track working!")
        }
    }

    private func _testReconnect(mode: SignalingMode) async throws {
        print("[\(mode)] Testing reconnection...")

        let reconnectWatcher = ReconnectWatcher()

        try await withRooms([
            roomTestingOptions(mode: mode, delegate: reconnectWatcher, canPublish: true),
            roomTestingOptions(mode: mode, canSubscribe: true),
        ]) { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            // Publish audio via TestAudioTrack (bypasses AudioManager)
            let audioTrack = TestAudioTrack()
            try await room1.localParticipant.publish(audioTrack: audioTrack)

            guard let publisherIdentity = room1.localParticipant.identity else {
                XCTFail("Publisher's identity is nil")
                return
            }

            guard let remoteParticipant = room2.remoteParticipants[publisherIdentity] else {
                XCTFail("Failed to lookup Publisher (RemoteParticipant)")
                return
            }

            // Wait for initial track subscription
            let didSubscribe = self.expectation(description: "Did subscribe to remote audio track")
            didSubscribe.assertForOverFulfill = false

            let watchParticipant = remoteParticipant.objectWillChange.sink { _ in
                if remoteParticipant.firstAudioPublication?.track != nil {
                    didSubscribe.fulfill()
                }
            }

            await self.fulfillment(of: [didSubscribe], timeout: 30)
            watchParticipant.cancel()

            let tracksBefore = room1.localParticipant.trackPublications.count
            print("[\(mode)] Tracks before reconnect: \(tracksBefore)")

            // Trigger quick reconnect
            let expectations = reconnectWatcher.expectReconnect(description: "quick reconnect")
            try await room1.debug_simulate(scenario: .quickReconnect)

            await self.fulfillment(of: [expectations.start, expectations.complete], timeout: 30)

            // Verify state after reconnect
            XCTAssertEqual(room1.connectionState, .connected, "Room should be connected after reconnect")

            let tracksAfter = room1.localParticipant.trackPublications.count
            print("[\(mode)] Tracks after reconnect: \(tracksAfter)")
            XCTAssertEqual(tracksBefore, tracksAfter, "Track count should be preserved after reconnect")

            print("[\(mode)] Test passed - reconnection working!")
        }
    }

    /// Test data channel send/receive.
    private func _testDataChannel(mode: SignalingMode) async throws {
        print("[\(mode)] Testing data channel...")

        struct TestPayload: Codable {
            let content: String
        }

        try await withRooms([
            roomTestingOptions(mode: mode, canPublish: true, canPublishData: true, canSubscribe: true),
            roomTestingOptions(mode: mode, canPublish: true, canPublishData: true, canSubscribe: true),
        ]) { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            let topic = "test_signaling_data"
            let testPayload = TestPayload(content: UUID().uuidString)
            let jsonData = try JSONEncoder().encode(testPayload)

            // Create watcher on receiver
            let room2Watcher: RoomWatcher<TestPayload> = room2.createWatcher()

            // Publish data
            try await room1.localParticipant.publish(data: jsonData, options: DataPublishOptions(topic: topic))
            print("[\(mode)] Sent data, waiting for receiver...")

            // Wait for received data
            let received = try await room2Watcher.didReceiveDataCompleters.completer(for: topic).wait()
            XCTAssertEqual(received.content, testPayload.content, "Received data should match sent data")

            print("[\(mode)] Test passed - data channel working!")
        }
    }

    /// Test full reconnect restores tracks.
    private func _testFullReconnect(mode: SignalingMode) async throws {
        print("[\(mode)] Testing full reconnect...")

        let reconnectWatcher = ReconnectWatcher()

        try await withRooms([
            roomTestingOptions(mode: mode, delegate: reconnectWatcher, canPublish: true),
        ]) { rooms in
            let room = rooms[0]

            // Publish audio via TestAudioTrack (bypasses AudioManager)
            let audioTrack = TestAudioTrack()
            try await room.localParticipant.publish(audioTrack: audioTrack)

            let tracksBefore = room.localParticipant.trackPublications.count
            print("[\(mode)] Tracks before full reconnect: \(tracksBefore)")

            // Set up expectations BEFORE triggering reconnect so no callbacks are missed
            let reconnectExpectations = reconnectWatcher.expectReconnect(description: "full reconnect")
            let tracksExpectation = reconnectWatcher.expectTracksRepublished(count: tracksBefore)

            // Simulate full reconnect (client-initiated, doesn't degrade server state)
            try await room.debug_simulate(scenario: .fullReconnect)
            print("[\(mode)] Simulated full reconnect, waiting for completion...")

            await self.fulfillment(
                of: [reconnectExpectations.start, reconnectExpectations.complete, tracksExpectation],
                timeout: 30
            )

            XCTAssertEqual(room.connectionState, .connected, "Room should be connected after full reconnect")

            let tracksAfter = room.localParticipant.trackPublications.count
            print("[\(mode)] Tracks after full reconnect: \(tracksAfter)")
            XCTAssertEqual(tracksBefore, tracksAfter, "Tracks should be restored after full reconnect")

            print("[\(mode)] Test passed - full reconnect working!")
        }
    }

    // swiftlint:disable:next function_body_length
    private func _testPublishManyTracks(mode: SignalingMode) async throws {
        print("[\(mode)] Testing publish many tracks...")

        try await withRooms([
            roomTestingOptions(mode: mode, canPublish: true),
            roomTestingOptions(mode: mode, canSubscribe: true),
        ]) { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            // Keep total track count modest — CI runners have limited resources.
            let audioCount = 3
            let videoCount = 3
            let totalExpected = audioCount + videoCount

            // Publish audio tracks
            for i in 0 ..< audioCount {
                let track = TestAudioTrack(name: "audio-\(i)")
                try await room1.localParticipant.publish(audioTrack: track)
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }

            // Publish video tracks using dummy pixel buffers (no network download needed)
            for i in 0 ..< videoCount {
                let track = LocalVideoTrack.createBufferTrack(name: "video-\(i)")
                guard let capturer = track.capturer as? BufferCapturer else {
                    XCTFail("Expected BufferCapturer")
                    return
                }
                // BufferCapturer requires at least one frame before publish (to resolve dimensions)
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
                if let pixelBuffer { capturer.capture(pixelBuffer) }
                try await room1.localParticipant.publish(videoTrack: track)
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }

            print("[\(mode)] Published \(totalExpected) tracks, waiting for subscriber...")

            guard let publisherIdentity = room1.localParticipant.identity else {
                XCTFail("Publisher's identity is nil")
                return
            }

            guard let remoteParticipant = room2.remoteParticipants[publisherIdentity] else {
                XCTFail("Failed to lookup Publisher (RemoteParticipant)")
                return
            }

            // Wait for subscriber to see all tracks
            let didReceiveAll = self.expectation(description: "Did receive all \(totalExpected) tracks")
            didReceiveAll.assertForOverFulfill = false

            let watchParticipant = remoteParticipant.objectWillChange.sink { _ in
                let trackCount = remoteParticipant.trackPublications.count
                if trackCount >= totalExpected {
                    didReceiveAll.fulfill()
                }
            }

            // Also check immediately in case tracks already arrived
            if remoteParticipant.trackPublications.count >= totalExpected {
                didReceiveAll.fulfill()
            }

            await self.fulfillment(of: [didReceiveAll], timeout: 60)
            watchParticipant.cancel()

            let subscriberTrackCount = remoteParticipant.trackPublications.count
            print("[\(mode)] Subscriber sees \(subscriberTrackCount) tracks")
            XCTAssertGreaterThanOrEqual(subscriberTrackCount, totalExpected,
                                        "Subscriber should see all \(totalExpected) published tracks")

            print("[\(mode)] Test passed - publish many tracks working!")
        }
    }

    /// Test two sequential quick reconnect cycles.
    private func _testDoubleReconnect(mode: SignalingMode) async throws {
        print("[\(mode)] Testing double reconnect...")

        let reconnectWatcher = ReconnectWatcher()

        try await withRooms([
            roomTestingOptions(mode: mode, delegate: reconnectWatcher, canPublish: true),
        ]) { rooms in
            let room = rooms[0]

            self.assertSignalingModeState(room, mode: mode)

            for attempt in 1 ... 2 {
                print("[\(mode)] Triggering reconnect attempt \(attempt)...")
                let expectations = reconnectWatcher.expectReconnect(description: "reconnect #\(attempt)")
                try await room.debug_simulate(scenario: .quickReconnect)

                await self.fulfillment(of: [expectations.start, expectations.complete], timeout: 30)
                XCTAssertEqual(room.connectionState, .connected, "Room should be connected after reconnect #\(attempt)")
                print("[\(mode)] Reconnect attempt \(attempt) succeeded")
            }

            print("[\(mode)] Test passed - double reconnect working!")
        }
    }
}
