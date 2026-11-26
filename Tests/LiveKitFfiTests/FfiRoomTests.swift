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
import LiveKitFFI
import LiveKitTransport
import Testing

// This target has no dependency on the v2 LiveKit module.
@Suite(.timeLimit(.minutes(1)))
struct FfiRoomTests {
    @Test(arguments: 0 ..< 3) func generatedRoomLifecycle(round: Int) async throws {
        LiveKitTransport.initialize()
        let url = ProcessInfo.processInfo.environment["LIVEKIT_TESTING_URL"] ?? "ws://127.0.0.1:19980"
        let name = "direct-\(round)-\(UUID())"
        let token = try roomToken(name: name)
        let room = FfiRoom()
        let events = room.events(options: .init())
        weak var releasedParticipant: FfiParticipant?
        weak var releasedPublication: FfiTrackPublication?
        weak var releasedTrack: FfiTrack?
        do {
            let source = try await room.createAudioTrack(name: "startup", channels: 1)
            let track = try source.info()
            releasedTrack = track
            let options = try startupOptions(track: track)
            let initial = try await room.connect(url: url, token: token, options: options)
            #expect(initial.room?.name == name)
            #expect(initial.localParticipant?.identity() == "direct")
            let participant = try #require(initial.localParticipant)
            let publication = try #require(initial.publications.first)
            releasedParticipant = participant
            releasedPublication = publication
            #expect(publication.name() == "startup")
            #expect(publication.participantIdentity() == "direct")
            try await room.setMetadata(metadata: "direct metadata")
            var received = false
            while let update = try await events.next() {
                if case let .participantMetadataChanged(participant, _) = update.event {
                    #expect(participant.metadata() == "direct metadata")
                    #expect(update.revision > initial.revision)
                    received = true
                    break
                }
            }
            #expect(received)
            #expect(participant.metadata() == "direct metadata", "A retained core handle observes the update")
            let controls = try room.publication(identity: "direct", sid: publication.sid())
            try await controls.setMuted(muted: true)
            #expect(publication.isMuted())
            await room.disconnect()
            #expect(participant.metadata() == "direct metadata")
            await #expect(throws: NativeSessionError.Closed) { try await room.setName(name: "closed") }
            #expect(room.state().connection == .disconnected)
            while try await events.next() != nil {}
        } catch {
            await room.disconnect()
            throw error
        }

        #expect(releasedParticipant == nil)
        #expect(releasedPublication == nil)
        #expect(releasedTrack == nil)
    }

    private func startupOptions(track: FfiTrack) throws -> FfiRoomOptions {
        var publish = defaultTrackPublishOptions()
        publish.source = .microphone
        return try FfiRoomOptions().withPublishTrack(track: track, publishOptions: publish)
    }

    private func roomToken(name: String) throws -> String {
        try tokenGenerate(options: .init(videoGrants: .init(
            roomCreate: false, roomList: false, roomRecord: false, roomAdmin: false,
            roomJoin: true, room: name, destinationRoom: "", canPublish: true,
            canSubscribe: true, canPublishData: true, canPublishSources: [],
            canUpdateOwnMetadata: true, ingressAdmin: false, hidden: false,
            recorder: false, agent: false,
        ), identity: "direct"), credentials: .init(key: "devkey", secret: "secret"))
    }

    @Test func cancellationBeforeConnect() async throws {
        let url = ProcessInfo.processInfo.environment["LIVEKIT_TESTING_URL"] ?? "ws://127.0.0.1:19980"
        let token = try roomToken(name: "cancelled")
        let cancelled = FfiRoom()
        await Task.detached { cancelled.cancel() }.value
        await #expect(throws: NativeSessionError.Cancelled) {
            _ = try await cancelled.connect(url: url, token: token, options: .init())
        }
        await cancelled.disconnect()
    }

    @Test func coreOptionsKeepDefaultsAndNestedValues() async throws {
        let defaults = FfiRoomOptions()
        let configured = try defaults
            .withConnectTimeout(value: 1.234567)
            .withSdk(sdk: "probe", sdkVersion: "1", otherSdks: "components:2")
            .withMaxStreamPayloadBytes(value: 1 << 33)
            .withRtcConfig(iceServers: [.init(urls: ["turn:localhost"], username: "u", password: "p")],
                           iceTransportPolicy: .relay, continualGatheringPolicy: .gatherOnce, enableSctpSnap: true)
        #expect(defaults.autoSubscribe())
        #expect(defaults.singlePeerConnection())
        #expect(defaults.joinRetries() == 3)
        #expect(defaults.iceServers().isEmpty)
        #expect(abs(configured.connectTimeout() - 1.234567) < 0.000001)
        #expect(configured.otherSdks() == "components:2")
        #expect(configured.iceServers().first?.password == "p")
        #expect(configured.enableSctpSnap())
        var publish = defaultTrackPublishOptions()
        #expect(publish.simulcast)
        #expect(publish.dtx && publish.red)
        #expect(publish.videoCodec == .vp8)
        #expect(publish.videoEncoding == nil)
        publish.videoEncoding = .init(maxBitrate: 500_000, maxFramerate: 30)
        publish.simulcastLayers = [.init(encoding: .init(maxBitrate: 100_000, maxFramerate: 15), width: 320, height: 180)]
        publish.videoCodec = .vp9
        publish.scalabilityMode = "L3T3_KEY"
        publish.frameMetadataFeatures = .init(userTimestamp: true, frameId: true, userData: true)
        #expect(publish.simulcastLayers?.first?.encoding.maxFramerate == 15)
        #expect(publish.frameMetadataFeatures.userData)
        let room = FfiRoom()
        do {
            let source = try await room.createVideoTrack(name: "options", width: 640, height: 360, screencast: false)
            let track = try source.info()
            let startup = try configured.withPublishTrack(track: track, publishOptions: publish)
            #expect(configured.publishTrackCount() == 0)
            #expect(startup.publishTrackCount() == 1)
            #expect(startup.publishTrackOptions() == [publish])
            #expect(track.name() == "options")
            try await source.setMuted(muted: true)
            #expect(track.isMuted())
            await room.disconnect()
        } catch {
            await room.disconnect()
            throw error
        }
    }
}
