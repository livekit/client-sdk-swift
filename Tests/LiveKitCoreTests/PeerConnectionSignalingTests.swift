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
import Testing
import XCTest
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

// MARK: - SignalingMode

enum SignalingMode: CustomStringConvertible, CaseIterable {
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

@Suite(.serialized, .tags(.e2e))
final class PeerConnectionSignalingTests: @unchecked Sendable {
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
            Issue.record("Transport is nil after connection")
            return
        }

        switch transport {
        case .publisherOnly:
            if mode == .dualPC {
                Issue.record("DualPC test should not have single-PC mode active")
            }
        case .subscriberPrimary, .publisherPrimary:
            if mode == .singlePC {
                let url = room.url ?? ""
                if url.contains("localhost") || url.contains("127.0.0.1") {
                    print("[\(mode)] SinglePC on localhost: fell back to dual PC (expected on older servers)")
                } else {
                    Issue.record("SinglePC requested on non-localhost URL should stay in single-PC mode")
                }
            }
        }
    }

    /// Helper to wait for XCTestExpectations from Swift Testing context.
    private func waitForExpectations(_ expectations: [XCTestExpectation], timeout: TimeInterval = 30) async {
        let result = await XCTWaiter().fulfillment(of: expectations, timeout: timeout)
        #expect(result == .completed, "Expectations not fulfilled in time")
    }

    /// Helper to poll for a condition with timeout.
    private func waitUntil(timeout: TimeInterval = 30, _ condition: @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        Issue.record("Timed out waiting for condition")
    }

    // MARK: - Parameterized Tests

    @Test(arguments: SignalingMode.allCases)
    func connect(mode: SignalingMode) async throws {
        print("[\(mode)] Testing basic connection...")

        try await TestEnvironment.withRooms([roomTestingOptions(mode: mode, canPublish: true)]) { rooms in
            let room = rooms[0]

            #expect(room.connectionState == .connected)
            #expect(room.localParticipant.identity != nil, "LocalParticipant.identity should not be nil")
            self.assertSignalingModeState(room, mode: mode)

            print("[\(mode)] Connected! Room: \(room.name ?? "nil")")
        }
    }

    @Test(arguments: SignalingMode.allCases)
    func twoParticipants(mode: SignalingMode) async throws {
        print("[\(mode)] Testing two participants...")

        try await TestEnvironment.withRooms([
            roomTestingOptions(mode: mode, canPublish: true, canSubscribe: true),
            roomTestingOptions(mode: mode, canPublish: true, canSubscribe: true),
        ]) { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            // withRooms already waits for participants to see each other
            #expect(room1.remoteParticipants.count == 1, "Room1 should see 1 remote participant")
            #expect(room2.remoteParticipants.count == 1, "Room2 should see 1 remote participant")

            self.assertSignalingModeState(room1, mode: mode)
            self.assertSignalingModeState(room2, mode: mode)
        }
    }

    @Test(arguments: SignalingMode.allCases)
    func audioTrack(mode: SignalingMode) async throws {
        print("[\(mode)] Testing audio track...")

        try await TestEnvironment.withRooms([
            roomTestingOptions(mode: mode, canPublish: true),
            roomTestingOptions(mode: mode, canSubscribe: true),
        ]) { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            guard let publisherIdentity = room1.localParticipant.identity else {
                Issue.record("Publisher's identity is nil")
                return
            }

            guard let remoteParticipant = room2.remoteParticipants[publisherIdentity] else {
                Issue.record("Failed to lookup Publisher (RemoteParticipant)")
                return
            }

            // Watch for remote audio track subscription
            let didSubscribe = XCTestExpectation(description: "Did subscribe to remote audio track")
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
            await self.waitForExpectations([didSubscribe])

            guard let remoteAudioTrack else {
                Issue.record("RemoteAudioTrack is nil")
                return
            }

            // Wait for actual audio frames
            let didReceiveFrame = XCTestExpectation(description: "Did receive audio frame")
            didReceiveFrame.assertForOverFulfill = false

            let audioWatcher = AudioTrackWatcher(id: "audio-watcher") { _ in
                didReceiveFrame.fulfill()
            }
            remoteAudioTrack.add(audioRenderer: audioWatcher)

            print("[\(mode)] Waiting for audio frames...")
            await self.waitForExpectations([didReceiveFrame])

            remoteAudioTrack.remove(audioRenderer: audioWatcher)
            watchParticipant.cancel()
        }
    }

    @Test(arguments: SignalingMode.allCases)
    func reconnect(mode: SignalingMode) async throws {
        print("[\(mode)] Testing reconnection...")

        let reconnectWatcher = ReconnectWatcher()

        try await TestEnvironment.withRooms([
            roomTestingOptions(mode: mode, delegate: reconnectWatcher, canPublish: true),
            roomTestingOptions(mode: mode, canSubscribe: true),
        ]) { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            // Publish audio via TestAudioTrack (bypasses AudioManager)
            let audioTrack = TestAudioTrack()
            try await room1.localParticipant.publish(audioTrack: audioTrack)

            guard let publisherIdentity = room1.localParticipant.identity else {
                Issue.record("Publisher's identity is nil")
                return
            }

            guard let remoteParticipant = room2.remoteParticipants[publisherIdentity] else {
                Issue.record("Failed to lookup Publisher (RemoteParticipant)")
                return
            }

            // Wait for initial track subscription
            let didSubscribe = XCTestExpectation(description: "Did subscribe to remote audio track")
            didSubscribe.assertForOverFulfill = false

            let watchParticipant = remoteParticipant.objectWillChange.sink { _ in
                if remoteParticipant.firstAudioPublication?.track != nil {
                    didSubscribe.fulfill()
                }
            }

            await self.waitForExpectations([didSubscribe])
            watchParticipant.cancel()

            let tracksBefore = room1.localParticipant.trackPublications.count
            print("[\(mode)] Tracks before reconnect: \(tracksBefore)")

            // Trigger quick reconnect
            let expectations = reconnectWatcher.expectReconnect(description: "quick reconnect")
            try await room1.debug_simulate(scenario: .quickReconnect)

            await self.waitForExpectations([expectations.start, expectations.complete])

            // Verify state after reconnect
            #expect(room1.connectionState == .connected, "Room should be connected after reconnect")

            let tracksAfter = room1.localParticipant.trackPublications.count
            print("[\(mode)] Tracks after reconnect: \(tracksAfter)")
            #expect(tracksBefore == tracksAfter, "Track count should be preserved after reconnect")
        }
    }

    @Test(arguments: SignalingMode.allCases)
    func dataChannel(mode: SignalingMode) async throws {
        print("[\(mode)] Testing data channel...")

        struct TestPayload: Codable {
            let content: String
        }

        try await TestEnvironment.withRooms([
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
            #expect(received.content == testPayload.content, "Received data should match sent data")
        }
    }

    @Test(arguments: SignalingMode.allCases)
    func fullReconnect(mode: SignalingMode) async throws {
        print("[\(mode)] Testing full reconnect...")

        let reconnectWatcher = ReconnectWatcher()

        try await TestEnvironment.withRooms([
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

            await self.waitForExpectations(
                [reconnectExpectations.start, reconnectExpectations.complete, tracksExpectation]
            )

            #expect(room.connectionState == .connected, "Room should be connected after full reconnect")

            let tracksAfter = room.localParticipant.trackPublications.count
            print("[\(mode)] Tracks after full reconnect: \(tracksAfter)")
            #expect(tracksBefore == tracksAfter, "Tracks should be restored after full reconnect")
        }
    }

    // swiftlint:disable:next function_body_length
    @Test(arguments: SignalingMode.allCases)
    func publishManyTracks(mode: SignalingMode) async throws {
        print("[\(mode)] Testing publish many tracks...")

        try await TestEnvironment.withRooms([
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
                    Issue.record("Expected BufferCapturer")
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
                Issue.record("Publisher's identity is nil")
                return
            }

            guard let remoteParticipant = room2.remoteParticipants[publisherIdentity] else {
                Issue.record("Failed to lookup Publisher (RemoteParticipant)")
                return
            }

            // Wait for subscriber to see all tracks via polling
            try await self.waitUntil(timeout: 60) {
                remoteParticipant.trackPublications.count >= totalExpected
            }

            let subscriberTrackCount = remoteParticipant.trackPublications.count
            print("[\(mode)] Subscriber sees \(subscriberTrackCount) tracks")
            #expect(subscriberTrackCount >= totalExpected,
                    "Subscriber should see all \(totalExpected) published tracks")
        }
    }

    @Test(arguments: SignalingMode.allCases)
    func doubleReconnect(mode: SignalingMode) async throws {
        print("[\(mode)] Testing double reconnect...")

        let reconnectWatcher = ReconnectWatcher()

        try await TestEnvironment.withRooms([
            roomTestingOptions(mode: mode, delegate: reconnectWatcher, canPublish: true),
        ]) { rooms in
            let room = rooms[0]

            self.assertSignalingModeState(room, mode: mode)

            for attempt in 1 ... 2 {
                print("[\(mode)] Triggering reconnect attempt \(attempt)...")
                let expectations = reconnectWatcher.expectReconnect(description: "reconnect #\(attempt)")
                try await room.debug_simulate(scenario: .quickReconnect)

                await self.waitForExpectations([expectations.start, expectations.complete])
                #expect(room.connectionState == .connected, "Room should be connected after reconnect #\(attempt)")
                print("[\(mode)] Reconnect attempt \(attempt) succeeded")
            }
        }
    }

    @Test func v1LocalhostFallback() async throws {
        let url = TestEnvironment.liveKitServerUrl()
        guard url.contains("localhost") || url.contains("127.0.0.1") else {
            print("Skipping localhost fallback test because LIVEKIT_TESTING_URL override is set")
            return
        }

        try await TestEnvironment.withRooms([roomTestingOptions(mode: .singlePC, canPublish: true)]) { rooms in
            let room = rooms[0]
            #expect(room.connectionState == .connected)

            guard let transport = room._state.transport else {
                Issue.record("Transport is nil")
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
