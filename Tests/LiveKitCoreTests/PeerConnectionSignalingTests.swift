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
///
/// Delegate callbacks set flags via `StateSync`, and tests poll with `waitForReconnect()`.
private final class ReconnectWatcher: NSObject, RoomDelegate, @unchecked Sendable {
    private struct State {
        var reconnectStarted = false
        var reconnectCompleted = false
        var tracksRepublished = false
        var expectedTrackCount: Int = 0
        var publishedTrackCount: Int = 0
        var isCountingRepublishedTracks = false
    }

    private let _state = StateSync(State())

    func prepareForReconnect(expectedTrackCount: Int = 0) {
        _state.mutate {
            $0.reconnectStarted = false
            $0.reconnectCompleted = false
            $0.tracksRepublished = false
            $0.expectedTrackCount = expectedTrackCount
            $0.publishedTrackCount = 0
            $0.isCountingRepublishedTracks = false
        }
    }

    /// Polls until reconnect start + complete (and optionally tracks republished).
    func waitForReconnect(withTracks: Bool = false, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = _state.copy()
            if state.reconnectStarted, state.reconnectCompleted,
               !withTracks || state.tracksRepublished
            {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let state = _state.copy()
        Issue.record("Reconnect timed out — started: \(state.reconnectStarted), completed: \(state.reconnectCompleted), tracks: \(state.tracksRepublished)")
    }

    // MARK: - RoomDelegate

    func room(_: Room, didStartReconnectWithMode _: ReconnectMode) {
        _state.mutate { $0.reconnectStarted = true }
    }

    func room(_: Room, didCompleteReconnectWithMode _: ReconnectMode) {
        _state.mutate {
            $0.reconnectCompleted = true
            $0.isCountingRepublishedTracks = true
        }
    }

    func room(_: Room, participant _: LocalParticipant, didPublishTrack _: LocalTrackPublication) {
        _state.mutate {
            guard $0.isCountingRepublishedTracks else { return }
            $0.publishedTrackCount += 1
            if $0.publishedTrackCount >= $0.expectedTrackCount {
                $0.tracksRepublished = true
            }
        }
    }
}

// MARK: - PeerConnectionSignalingTests

@Suite(.serialized, .tags(.e2e))
struct PeerConnectionSignalingTests {
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

    /// Polls `objectWillChange` for a condition to become true.
    private func waitForPublish<T: ObservableObject & Sendable>(
        on participant: T,
        timeout: TimeInterval = 30,
        _ condition: @Sendable @escaping (T) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(participant) { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        Issue.record("Timed out waiting for participant publish condition")
    }

    // MARK: - Parameterized Tests

    @Test(arguments: SignalingMode.allCases)
    func connect(mode: SignalingMode) async throws {
        try await TestEnvironment.withRooms([roomTestingOptions(mode: mode, canPublish: true)]) { rooms in
            let room = rooms[0]

            #expect(room.connectionState == .connected)
            #expect(room.localParticipant.identity != nil, "LocalParticipant.identity should not be nil")
            assertSignalingModeState(room, mode: mode)
        }
    }

    @Test(arguments: SignalingMode.allCases)
    func twoParticipants(mode: SignalingMode) async throws {
        try await TestEnvironment.withRooms([
            roomTestingOptions(mode: mode, canPublish: true, canSubscribe: true),
            roomTestingOptions(mode: mode, canPublish: true, canSubscribe: true),
        ]) { rooms in
            #expect(rooms[0].remoteParticipants.count == 1, "Room1 should see 1 remote participant")
            #expect(rooms[1].remoteParticipants.count == 1, "Room2 should see 1 remote participant")

            assertSignalingModeState(rooms[0], mode: mode)
            assertSignalingModeState(rooms[1], mode: mode)
        }
    }

    @Test(arguments: SignalingMode.allCases)
    func audioTrack(mode: SignalingMode) async throws {
        try await TestEnvironment.withRooms([
            roomTestingOptions(mode: mode, canPublish: true),
            roomTestingOptions(mode: mode, canSubscribe: true),
        ]) { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            let publisherIdentity = try #require(room1.localParticipant.identity)
            let remoteParticipant = try #require(room2.remoteParticipants[publisherIdentity])

            // Publish audio via TestAudioTrack (bypasses AudioManager)
            let audioTrack = TestAudioTrack()
            try await room1.localParticipant.publish(audioTrack: audioTrack)

            // Wait for remote audio track subscription
            try await waitForPublish(on: remoteParticipant) {
                $0.firstAudioPublication?.track is RemoteAudioTrack
            }

            let remoteAudioTrack = try #require(
                remoteParticipant.firstAudioPublication?.track as? RemoteAudioTrack
            )

            // Wait for actual audio frames via polling
            let audioWatcher = AudioTrackWatcher(id: "audio-watcher")
            remoteAudioTrack.add(audioRenderer: audioWatcher)
            defer { remoteAudioTrack.remove(audioRenderer: audioWatcher) }

            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline, !audioWatcher.didRenderFirstFrame {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            #expect(audioWatcher.didRenderFirstFrame, "Should have received audio frames")
        }
    }

    @Test(arguments: SignalingMode.allCases)
    func reconnect(mode: SignalingMode) async throws {
        let reconnectWatcher = ReconnectWatcher()

        try await TestEnvironment.withRooms([
            roomTestingOptions(mode: mode, delegate: reconnectWatcher, canPublish: true),
            roomTestingOptions(mode: mode, canSubscribe: true),
        ]) { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            let audioTrack = TestAudioTrack()
            try await room1.localParticipant.publish(audioTrack: audioTrack)

            let publisherIdentity = try #require(room1.localParticipant.identity)
            let remoteParticipant = try #require(room2.remoteParticipants[publisherIdentity])

            // Wait for initial track subscription
            try await waitForPublish(on: remoteParticipant) {
                $0.firstAudioPublication?.track != nil
            }

            let tracksBefore = room1.localParticipant.trackPublications.count

            // Trigger quick reconnect
            reconnectWatcher.prepareForReconnect()
            try await room1.debug_simulate(scenario: .quickReconnect)
            try await reconnectWatcher.waitForReconnect()

            #expect(room1.connectionState == .connected, "Room should be connected after reconnect")
            #expect(room1.localParticipant.trackPublications.count == tracksBefore, "Track count should be preserved")
        }
    }

    @Test(arguments: SignalingMode.allCases)
    func dataChannel(mode: SignalingMode) async throws {
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

            let room2Watcher: RoomWatcher<TestPayload> = room2.createWatcher()

            try await room1.localParticipant.publish(data: jsonData, options: DataPublishOptions(topic: topic))

            let received = try await room2Watcher.didReceiveDataCompleters.completer(for: topic).wait()
            #expect(received.content == testPayload.content, "Received data should match sent data")
        }
    }

    @Test(arguments: SignalingMode.allCases)
    func fullReconnect(mode: SignalingMode) async throws {
        let reconnectWatcher = ReconnectWatcher()

        try await TestEnvironment.withRooms([
            roomTestingOptions(mode: mode, delegate: reconnectWatcher, canPublish: true),
        ]) { rooms in
            let room = rooms[0]

            let audioTrack = TestAudioTrack()
            try await room.localParticipant.publish(audioTrack: audioTrack)

            let tracksBefore = room.localParticipant.trackPublications.count

            reconnectWatcher.prepareForReconnect(expectedTrackCount: tracksBefore)
            try await room.debug_simulate(scenario: .fullReconnect)
            try await reconnectWatcher.waitForReconnect(withTracks: true)

            #expect(room.connectionState == .connected, "Room should be connected after full reconnect")
            #expect(room.localParticipant.trackPublications.count == tracksBefore, "Tracks should be restored")
        }
    }

    @Test(arguments: SignalingMode.allCases)
    func publishManyTracks(mode: SignalingMode) async throws {
        try await TestEnvironment.withRooms([
            roomTestingOptions(mode: mode, canPublish: true),
            roomTestingOptions(mode: mode, canSubscribe: true),
        ]) { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            let audioCount = 3
            let videoCount = 3
            let totalExpected = audioCount + videoCount

            for i in 0 ..< audioCount {
                let track = TestAudioTrack(name: "audio-\(i)")
                try await room1.localParticipant.publish(audioTrack: track)
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            for i in 0 ..< videoCount {
                let track = LocalVideoTrack.createBufferTrack(name: "video-\(i)")
                guard let capturer = track.capturer as? BufferCapturer else {
                    Issue.record("Expected BufferCapturer")
                    return
                }
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
                if let pixelBuffer { capturer.capture(pixelBuffer) }
                try await room1.localParticipant.publish(videoTrack: track)
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            let publisherIdentity = try #require(room1.localParticipant.identity)
            let remoteParticipant = try #require(room2.remoteParticipants[publisherIdentity])

            // Poll until subscriber sees all tracks
            try await waitForPublish(on: remoteParticipant, timeout: 60) {
                $0.trackPublications.count >= totalExpected
            }

            #expect(remoteParticipant.trackPublications.count >= totalExpected,
                    "Subscriber should see all \(totalExpected) published tracks")
        }
    }

    @Test(arguments: SignalingMode.allCases)
    func doubleReconnect(mode: SignalingMode) async throws {
        let reconnectWatcher = ReconnectWatcher()

        try await TestEnvironment.withRooms([
            roomTestingOptions(mode: mode, delegate: reconnectWatcher, canPublish: true),
        ]) { rooms in
            let room = rooms[0]

            assertSignalingModeState(room, mode: mode)

            for attempt in 1 ... 2 {
                reconnectWatcher.prepareForReconnect()
                try await room.debug_simulate(scenario: .quickReconnect)
                try await reconnectWatcher.waitForReconnect()
                #expect(room.connectionState == .connected, "Room should be connected after reconnect #\(attempt)")
            }
        }
    }

    @Test(.enabled(if: {
        let url = TestEnvironment.liveKitServerUrl()
        return url.contains("localhost") || url.contains("127.0.0.1")
    }(), "Requires localhost server"))
    func v1LocalhostFallback() async throws {
        try await TestEnvironment.withRooms([roomTestingOptions(mode: .singlePC, canPublish: true)]) { rooms in
            let room = rooms[0]
            #expect(room.connectionState == .connected)

            let transport = try #require(room._state.transport, "Transport is nil")

            switch transport {
            case .publisherOnly:
                print("Localhost server supports /rtc/v1 (single PC active)")
            case .subscriberPrimary, .publisherPrimary:
                print("Localhost server fell back to V0 as expected")
            }
        }
    }
}
