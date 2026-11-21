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
import LiveKitTestSupport
import Testing

@Suite(.serialized, .tags(.e2e), TestLimits.e2e)
struct PublishWithJoinTests {
    private func token(canPublish: Bool = true) throws -> String {
        try TestEnvironment.liveKitServerToken(for: UUID().uuidString, identity: "initial-publisher",
                                               canPublish: canPublish, canPublishData: true)
    }

    @Test(arguments: [true, false])
    func publishesAudioAndVideoBeforeReturning(singlePC: Bool) async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: singlePC))
        let audio = TestAudioTrack()
        let video = await LocalVideoTrack.createBufferTrack(options: BufferCaptureOptions(dimensions: .h180_169))
        let capturer = try #require(video.capturer as? BufferCapturer)
        let feeder = capturer.startFeedingFrames(dimensions: .h180_169)
        defer { feeder.cancel() }
        do {
            try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: token(),
                                   publishTracks: [InitialTrack(track: audio), InitialTrack(track: video)])
            #expect(room.connectionState == .connected)
            #expect(room.localParticipant.localAudioTracks.count == 1)
            #expect(room.localParticipant.localVideoTracks.count == 1)
            #expect(audio.publishState == .published)
            #expect(video.publishState == .published)
        } catch {
            await room.disconnect()
            throw error
        }
        await room.disconnect()
        #expect(audio._state.rtpSender == nil)
        #expect(video._state.rtpSender == nil)
    }

    @Test func rejectedPublicationClosesRoomAndDetachesSender() async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        let track = TestAudioTrack()
        do {
            try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: token(canPublish: false),
                                   publishTracks: [InitialTrack(track: track)])
            Issue.record("A participant without publish permission connected with a track")
            await room.disconnect()
        } catch {
            #expect(room.connectionState == .disconnected)
            #expect(track._state.rtpSender == nil)
            #expect(room.localParticipant.trackPublications.isEmpty)
        }
    }

    @Test func duplicateTracksFailBeforeConnecting() async throws {
        let room = Room()
        let track = TestAudioTrack()
        do {
            try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: token(),
                                   publishTracks: [InitialTrack(track: track), InitialTrack(track: track)])
            Issue.record("Duplicate initial tracks were accepted")
        } catch {
            #expect(room.connectionState == .disconnected)
            #expect(track._state.rtpSender == nil)
        }
        await room.disconnect()
    }

    @Test func abandoningEarlyPublisherDetachesItsTracks() async throws {
        let room = Room()
        let track = TestAudioTrack()
        let early = try await EarlyPublisher.make(room: room, rtcConfiguration: .liveKitDefault(),
                                                  publishTracks: [InitialTrack(track: track)])
        #expect(early.offer != nil)
        #expect(early.preparedTracks.count == 1)
        #expect(track._state.rtpSender != nil)
        await early.close()
        #expect(track._state.rtpSender == nil)
    }

    @Test func joinTimeVideoOfferKeepsItsStartBitrateHint() async throws {
        let room = Room()
        let track = await LocalVideoTrack.createBufferTrack(options: BufferCaptureOptions(dimensions: .h720_169))
        let capturer = try #require(track.capturer as? BufferCapturer)
        let feeder = capturer.startFeedingFrames(dimensions: .h720_169)
        defer { feeder.cancel() }
        let early = try await EarlyPublisher.make(room: room, rtcConfiguration: .liveKitDefault(),
                                                  publishTracks: [InitialTrack(track: track)])
        #expect(early.offer.map { Transport.carriesVideoStartBitrate($0.sdp) } == true)
        #expect(await early.transport.localDescription == nil)
        await early.close()
        try await track.stop()
    }

    @Test func cancellingConnectDetachesJoinTimeSender() async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        let track = TestAudioTrack()
        let token = try token()
        let connecting = Task {
            try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: token,
                                   connectOptions: ConnectOptions(iceTransportPolicy: .relay),
                                   publishTracks: [InitialTrack(track: track)])
        }
        do {
            try await poll(timeout: 5, for: "the join-time sender is attached") {
                track._state.rtpSender != nil
            }
        } catch {
            connecting.cancel()
            _ = await connecting.result
            await room.disconnect()
            throw error
        }
        connecting.cancel()
        if case .success = await connecting.result {
            Issue.record("Connect finished before it could be cancelled")
        }
        #expect(room.connectionState == .disconnected)
        #expect(track._state.rtpSender == nil)
    }

    @Test func encryptedRoomPublishesAfterJoining() async throws {
        let provider = BaseKeyProvider()
        let options = RoomOptions(encryptionOptions: EncryptionOptions(keyProvider: provider), singlePeerConnection: true)
        let room = Room(roomOptions: options)
        let track = TestAudioTrack()
        do {
            try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: token(),
                                   publishTracks: [InitialTrack(track: track)])
            let publication = try #require(room.localParticipant.localAudioTracks.first)
            #expect(publication.encryptionType == .gcm)
            #expect(track.publishState == .published)
        } catch {
            await room.disconnect()
            throw error
        }
        await room.disconnect()
    }

    @Test func fullReconnectDoesNotReplayInitialInputs() async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        let track = TestAudioTrack()
        do {
            try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: token(),
                                   publishTracks: [InitialTrack(track: track)])
            let original = try #require(room.localParticipant.localAudioTracks.first).sid
            try await room.debug_simulate(scenario: .fullReconnect)
            try await poll(timeout: 30, for: "the track is republished once") {
                room.connectionState == .connected && room.localParticipant.localAudioTracks.count == 1
                    && room.localParticipant.localAudioTracks.first?.sid != original
            }
            #expect(room.localParticipant.localAudioTracks.first?.track === track)
        } catch {
            await room.disconnect()
            throw error
        }
        await room.disconnect()
    }

    @Test func unpublishingReleasesInitialTrack() async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        let weakTrack = WeakTrack()
        do {
            try await publishAndUnpublish(in: room, weakTrack: weakTrack)
            try await poll(timeout: 5, for: "the connect call releases its initial track") {
                weakTrack.track == nil
            }
        } catch {
            await room.disconnect()
            throw error
        }
        await room.disconnect()
    }

    private func publishAndUnpublish(in room: Room, weakTrack: WeakTrack) async throws {
        let track = TestAudioTrack()
        weakTrack.track = track
        try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: token(),
                               publishTracks: [InitialTrack(track: track)])
        let publication = try #require(room.localParticipant.localAudioTracks.first)
        try await room.localParticipant.unpublish(publication: publication)
    }
}

private final class WeakTrack: @unchecked Sendable {
    weak var track: Track?
}
