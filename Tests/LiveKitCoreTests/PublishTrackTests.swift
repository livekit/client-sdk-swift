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

@Suite(.serialized, .tags(.media, .e2e))
struct PublishTrackTests {
    @Test func publishFailureAfterAddTrackRollsBack() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true), RoomTestingOptions(canSubscribe: true)]) { rooms in
            let publisher = rooms[0].localParticipant
            let publisherIdentity = try #require(publisher.identity)
            let remote = try #require(rooms[1].remoteParticipants[publisherIdentity])

            let failedTrack = FrameStarvedAudioTrack()
            await #expect(throws: LiveKitError.self) {
                try await publisher.publish(audioTrack: failedTrack)
            }
            #expect(publisher.audioTracks.isEmpty)
            #expect(failedTrack._state.rtpSender == nil)

            // A retry must leave exactly one track on the server, not a second one next to an orphan.
            let publication = try await publisher.publish(audioTrack: TestAudioTrack())
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, Set(remote.audioTracks.map(\.sid)) != [publication.sid] {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            #expect(Set(remote.audioTracks.map(\.sid)) == [publication.sid])
        }
    }

    @Test func publishWithoutPermissions() async throws {
        try await TestEnvironment.withRoom(RoomTestingOptions(canPublish: false)) { room in
            let audioTrack = await LocalAudioTrack.createTrack()

            await #expect(throws: LiveKitError.self) {
                try await room.localParticipant.publish(audioTrack: audioTrack)
            }
        }
    }

    @Test func publishWithDisallowedSource() async throws {
        try await TestEnvironment.withRoom(RoomTestingOptions(canPublish: true, canPublishSources: [.camera])) { room in
            let audioTrack = await LocalAudioTrack.createTrack()

            await #expect(throws: LiveKitError.self) {
                try await room.localParticipant.publish(audioTrack: audioTrack)
            }
        }
    }
}
