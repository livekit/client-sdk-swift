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
            let relationship = try #require(initial.publications.first)
            let publication = relationship.publication
            releasedParticipant = participant
            releasedPublication = publication
            checkCoreObjects(participant: participant, publication: publication, track: track)
            #expect(relationship.participant.identity() == "direct")
            try await room.setMetadata(metadata: "direct metadata")
            try await expectMetadata(events: events, after: initial.revision)
            #expect(participant.metadata() == "direct metadata", "A retained core handle observes the update")
            let controls = try room.publication(identity: "direct", sid: publication.sid())
            try await controls.setMuted(muted: true)
            #expect(publication.isMuted())
            try await room.disconnect()
            #expect(participant.metadata() == "direct metadata")
            await #expect(throws: FfiRoomError.Closed) { try await room.setName(name: "closed") }
            #expect(room.state().connection == .disconnected)
            while try await events.next() != nil {}
        } catch {
            try await room.disconnect()
            throw error
        }

        #expect(releasedParticipant == nil)
        #expect(releasedPublication == nil)
        #expect(releasedTrack == nil)
    }

    @Test func generatedTypedObservationOwnsValuesAndCancellation() async throws {
        LiveKitTransport.initialize()
        let url = ProcessInfo.processInfo.environment["LIVEKIT_TESTING_URL"] ?? "ws://127.0.0.1:19980"
        let room = FfiRoom()
        let events = room.events(options: .init())
        defer { events.cancel(); room.cancel() }
        let source = try await room.createAudioTrack(name: "observed", channels: 1)
        let track = try source.info()
        let initial = try await room.connect(url: url, token: roomToken(name: "observe-\(UUID())"), options: startupOptions(track: track))
        let participant = try #require(initial.localParticipant)
        let publication = try #require(initial.publications.first?.publication)
        let observer = participant.observeState()
        let sibling = participant.observeState()
        let historical = try #require(await observer.stateDidChange(since: nil))
        let trackObserver = track.observeState()
        let historicalTrack = trackObserver.state()
        let publicationState = publication.observeState().state()
        #expect(publicationState.values.publishOptions?.source == .microphone)
        #expect(publicationState.track?.name() == "observed")
        try await room.setMetadata(metadata: "direct metadata")
        try await expectMetadata(events: events, after: initial.revision)
        let changed = try #require(await observer.stateDidChange(since: historical.revision))
        #expect(changed.values.metadata == "direct metadata")
        #expect(historical.values.metadata != changed.values.metadata)
        #expect(await sibling.stateDidChange(since: historical.revision)?.values.metadata == "direct metadata")
        try await source.setMuted(muted: true)
        #expect(await trackObserver.stateDidChange(since: historicalTrack.revision)?.values.muted == true)
        #expect(!historicalTrack.values.muted)
        await Task.detached { observer.cancel() }.value
        #expect(await observer.stateDidChange(since: changed.revision) == nil)
        #expect(room.state().connection == .connected)
        try await room.disconnect()
        let terminal = sibling.state()
        #expect(terminal.terminal)
        #expect(await sibling.stateDidChange(since: terminal.revision) == nil)
        #expect(!trackObserver.state().terminal, "Local tracks retain their reusable lifetime")
    }

    @Test func remoteRemovalFinishesOnlyRemovedObjects() async throws {
        LiveKitTransport.initialize()
        let url = ProcessInfo.processInfo.environment["LIVEKIT_TESTING_URL"] ?? "ws://127.0.0.1:19980"
        let name = "removed-\(UUID())"
        let receiver = FfiRoom()
        let sender = FfiRoom()
        let events = receiver.events(options: .init())
        defer { events.cancel(); receiver.cancel(); sender.cancel() }
        _ = try await receiver.connect(url: url, token: roomToken(name: name), options: .init())
        let audio = try await sender.createAudioTrack(name: "remote observation", channels: 1)
        _ = try await sender.connect(url: url, token: roomToken(name: name, identity: "sender"), options: startupOptions(track: audio.info()))
        let entry = try await subscribedPublication(events)
        let participant = entry.participant.observeState()
        let publication = entry.publication.observeState()
        let original = publication.state()
        let track = try #require(original.track).observeState()
        #expect(!participant.state().terminal)
        #expect(!original.terminal)
        #expect(!track.state().terminal)
        try await sender.disconnect()
        while let update = try await events.next() {
            if case .participantDisconnected = update.event { break }
        }
        #expect(participant.state().terminal)
        #expect(publication.state().terminal)
        #expect(track.state().terminal)
        #expect(!original.terminal, "Historical values do not change on removal")
        #expect(receiver.state().connection == .connected)
        #expect(await publication.stateDidChange(since: publication.state().revision) == nil)
        try await receiver.disconnect()
    }

    private func subscribedPublication(_ events: NativeRoomEventCursor) async throws -> FfiPublication {
        while let update = try await events.next() {
            if case let .trackSubscribed(publication, _) = update.event { return publication }
        }
        throw FfiRoomError.Closed
    }

    private func expectMetadata(events: NativeRoomEventCursor, after revision: UInt64) async throws {
        var received = false
        while let update = try await events.next() {
            if case let .participantMetadataChanged(participant, _, metadata) = update.event {
                #expect(metadata == "direct metadata")
                #expect(participant.metadata() == metadata)
                #expect(update.revision > revision)
                received = true
                break
            }
        }
        #expect(received)
    }

    private func checkCoreObjects(participant: FfiParticipant, publication: FfiTrackPublication, track: FfiTrack) {
        #expect(publication.name() == "startup")
        #expect(participant.publications()[publication.sid()]?.name() == "startup")
        #expect(publication.local()?.publishOptions().source == .microphone)
        #expect(publication.remote() == nil)
        #expect(publication.mediaTrack()?.name() == "startup")
        #expect(publication.dimensions().width() == 0)
        #expect(track.streamState() == .active)
    }

    private func startupOptions(track: FfiTrack) throws -> FfiRoomOptions {
        var publish = defaultTrackPublishOptions()
        publish.source = .microphone
        return try FfiRoomOptions().withPublishTrack(track: track, publishOptions: publish)
    }

    private func roomToken(name: String, identity: String = "direct") throws -> String {
        try tokenGenerate(options: .init(videoGrants: .init(
            roomCreate: false, roomList: false, roomRecord: false, roomAdmin: false,
            roomJoin: true, room: name, destinationRoom: "", canPublish: true,
            canSubscribe: true, canPublishData: true, canPublishSources: [],
            canUpdateOwnMetadata: true, ingressAdmin: false, hidden: false,
            recorder: false, agent: false,
        ), identity: identity), credentials: .init(key: "devkey", secret: "secret"))
    }

    @Test func cancellationBeforeConnect() async throws {
        let url = ProcessInfo.processInfo.environment["LIVEKIT_TESTING_URL"] ?? "ws://127.0.0.1:19980"
        let token = try roomToken(name: "cancelled")
        let cancelled = FfiRoom()
        await Task.detached { cancelled.cancel() }.value
        await #expect(throws: FfiRoomError.Cancelled) {
            _ = try await cancelled.connect(url: url, token: token, options: .init())
        }
        try await cancelled.disconnect()
    }

    @Test func ffiOptionsKeepCoreDefaultsAndNestedValues() async throws {
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
            try await room.disconnect()
        } catch {
            try await room.disconnect()
            throw error
        }
    }
}
