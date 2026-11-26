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

@Suite(.serialized, .tags(.media, .e2e), TestLimits.e2e)
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

    /// The server turns Opus DTX on in its answer unless the track carries `TF_NO_DTX`.
    @Test(arguments: [false, true])
    func audioTrackWithoutOptionsKeepsRoomDefaults(singlePeerConnection: Bool) async throws {
        let noDtx = AudioPublishOptions(dtx: false)
        let options = RoomTestingOptions(singlePeerConnection: singlePeerConnection, defaultAudioPublishOptions: noDtx, canPublish: true)

        try await TestEnvironment.withRoom(options) { room in
            let track = TestAudioTrack()
            let publication = try await room.localParticipant.publish(audioTrack: track)

            #expect(track.publishOptions as? AudioPublishOptions == noDtx)
            #expect(publication._state.audioTrackFeatures?.contains(.tfNoDtx) == true)

            let publisher = try #require(room._state.transport?.publisher)
            var answered: String?
            let deadline = Date().addingTimeInterval(15)
            while answered == nil, Date() < deadline {
                answered = await publisher.remoteDescription?.sdp.components(separatedBy: "m=")
                    .first { $0.hasPrefix("audio") && $0.contains("a=recvonly") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let section = try #require(answered, "the server never answered the audio section")
            #expect(section.contains("a=fmtp:111"))
            #expect(!section.contains("usedtx=1"))
        }
    }

    /// The server keeps the features it was last sent, so a runtime processing change has to re-send them.
    @Test func runtimeAudioProcessingChangeUpdatesFeatures() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true), RoomTestingOptions(canSubscribe: true)]) { rooms in
            let publisher = rooms[0].localParticipant
            let publisherIdentity = try #require(publisher.identity)
            let remote = try #require(rooms[1].remoteParticipants[publisherIdentity])

            let track = TestAudioTrack()
            let publication = try await publisher.publish(audioTrack: track)

            let voiceFeatures: Set<Livekit_AudioTrackFeature> = [.tfEchoCancellation, .tfNoiseSuppression, .tfAutoGainControl]
            var remoteFeatures: Set<Livekit_AudioTrackFeature> = []

            var deadline = Date().addingTimeInterval(15)
            while !remoteFeatures.isSuperset(of: voiceFeatures), Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
                remoteFeatures = Set(remote.trackPublications[publication.sid]?._state.latestInfo?.audioFeatures ?? [])
            }
            #expect(remoteFeatures.isSuperset(of: voiceFeatures))

            try track.setAudioProcessingOptions(.noProcessing)

            deadline = Date().addingTimeInterval(15)
            while !remoteFeatures.isDisjoint(with: voiceFeatures), Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
                remoteFeatures = Set(remote.trackPublications[publication.sid]?._state.latestInfo?.audioFeatures ?? [])
            }
            #expect(publication._state.audioTrackFeatures?.isDisjoint(with: voiceFeatures) == true)
            #expect(remoteFeatures.isDisjoint(with: voiceFeatures))
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
