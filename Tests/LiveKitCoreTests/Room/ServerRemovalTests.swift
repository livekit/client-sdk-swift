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
import LiveKitFFI
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// The server's own end of a session is a leave and then a close frame. A close frame fails the signalling stream, so
/// that the client reconnects when the server drops it; it must not turn a removal into a reconnect.
@Suite(.serialized, .tags(.e2e), .bug("https://github.com/livekit/client-sdk-swift/pull/1179"), TestLimits.e2e) final class ServerRemovalTests: @unchecked Sendable {
    private let reconnects = StateSync(0)
    private let disconnects = StateSync(0)
    private let unpublishes = StateSync(0)
    private let disconnectError = StateSync<LiveKitError?>(nil)

    @Test func aRemovedParticipantDisconnectsWithoutReconnecting() async throws {
        try await TestEnvironment.withRoom(RoomTestingOptions(delegate: self, canPublish: true)) { room in
            let dimensions = Dimensions(width: 320, height: 240)
            let track = await LocalVideoTrack.createBufferTrack(options: BufferCaptureOptions(dimensions: dimensions))
            let capturer = try #require(track.capturer as? BufferCapturer)
            capturer.set(dimensions: dimensions)
            try await room.localParticipant.publish(videoTrack: track)
            #expect(track.trackState == .started)
            let name = try #require(room.name)
            let identity = try #require(room.localParticipant.identity?.stringValue)
            try await Self.removeParticipant(identity, from: name)
            try await poll(timeout: 10, for: "the removed participant's room to disconnect") {
                self.disconnects.copy() > 0
            }
            #expect(room.connectionState == .disconnected)
            #expect(self.disconnectError.copy()?.type == .participantRemoved)
            #expect(self.reconnects.copy() == 0)
            #expect(track.trackState == .stopped)
            #expect(self.unpublishes.copy() == 1)
        }
    }

    /// RoomService.RemoveParticipant over Twirp, with a room admin token.
    private static func removeParticipant(_ identity: String, from room: String) async throws {
        let generator = TokenGenerator(apiKey: TestEnvironment.readEnvironmentString(for: "LIVEKIT_TESTING_API_KEY", defaultValue: "devkey"),
                                       apiSecret: TestEnvironment.readEnvironmentString(for: "LIVEKIT_TESTING_API_SECRET", defaultValue: "secret"),
                                       identity: "admin")
        generator.videoGrants = VideoGrants(
            roomCreate: false,
            roomList: false,
            roomRecord: false,
            roomAdmin: true,
            roomJoin: false,
            room: room,
            destinationRoom: "",
            canPublish: false,
            canSubscribe: false,
            canPublishData: false,
            canPublishSources: [],
            canUpdateOwnMetadata: false,
            ingressAdmin: false,
            hidden: false,
            recorder: false,
            agent: false,
        )
        let base = TestEnvironment.liveKitServerUrl()
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
        var request = try URLRequest(url: #require(URL(string: "\(base)/twirp/livekit.RoomService/RemoveParticipant")))
        request.httpMethod = "POST"
        try request.addValue("Bearer \(generator.sign())", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["room": room, "identity": identity])
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}

extension ServerRemovalTests: RoomDelegate {
    func room(_: Room, participant _: LocalParticipant, didUnpublishTrack _: LocalTrackPublication) {
        unpublishes.mutate { $0 += 1 }
    }

    func room(_: Room, didStartReconnectWithMode _: ReconnectMode) {
        reconnects.mutate { $0 += 1 }
    }

    func roomIsReconnecting(_: Room) {
        reconnects.mutate { $0 += 1 }
    }

    func room(_: Room, didDisconnectWithError error: LiveKitError?) {
        disconnectError.mutate { $0 = $0 ?? error }
        disconnects.mutate { $0 += 1 }
    }
}
