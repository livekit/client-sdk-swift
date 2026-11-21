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
struct SessionStartupTests {
    @Test(arguments: [true, false], [true, false])
    @MainActor func joinsBeforeCaptureAndPublishesOnce(singlePC: Bool, preConnectAudio: Bool) async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: singlePC))
        let session = try makeSession(room: room, preConnectAudio: preConnectAudio)
        let capture = AsyncCompleter<Void>(label: "capture permission", defaultTimeout: 10)
        let track = await RTC.run { TestAudioTrack() }
        session.startupDependencies.makeTrack = { _ in track }
        session.startupDependencies.startCapture = { track in
            try await capture.wait()
            try await track.start()
        }
        let starting = Task { await session.start() }
        do {
            try await poll(timeout: 10, for: "JOIN before microphone permission") { room.connectionState == .connected }
            #expect(room.localParticipant.localAudioTracks.isEmpty)
            #expect(!(room.preConnectBuffer.recorder?.isRecording ?? false))
            capture.resume(returning: ())
            await starting.value
            #expect(session.error == nil)
            let publication = try #require(room.localParticipant.localAudioTracks.first)
            #expect(room.localParticipant.localAudioTracks.count == 1)
            #expect(publication.track === track)
            #expect(track.publishState == .published)
            let cid = try #require(track._state.publicationCid)
            #expect((cid != track.mediaTrack.trackId) == singlePC)
            #expect(room.localParticipant.publishedTracksInfo().first?.cid == cid)
            await session.end()
            #expect(track._state.rtpSender == nil)
            #expect(track.trackState == .stopped)
        } catch {
            starting.cancel()
            capture.resume(throwing: CancellationError())
            await session.end()
            await starting.value
            throw error
        }
    }

    @Test @MainActor func endingDuringPermissionCannotPublishOrDisconnectNextAttempt() async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        let session = try makeSession(room: room)
        let abandonedTrack = await RTC.run { PermissionDelayedAudioTrack() }
        let gate = abandonedTrack.permission
        session.startupDependencies.makeTrack = { _ in abandonedTrack }
        let first = Task { await session.start() }
        do {
            try await poll(timeout: 10, for: "the first attempt to join") { room.connectionState == .connected }
            await session.end()
            await first.value
            let nextTrack = await RTC.run { TestAudioTrack() }
            session.startupDependencies.makeTrack = { _ in nextTrack }
            session.startupDependencies.startCapture = { try await $0.start() }
            await session.start()
            #expect(session.error == nil)
            await gate.release()
            try await abandonedTrack.stopped.wait()
            try await poll(timeout: 5, for: "late permission callback cleanup") { abandonedTrack.trackState == .stopped }
            #expect(room.connectionState == .connected)
            #expect(room.localParticipant.localAudioTracks.count == 1)
            #expect(room.localParticipant.localAudioTracks.first?.track === nextTrack)
            #expect(abandonedTrack._state.rtpSender == nil)
            await session.end()
        } catch {
            await gate.release()
            await session.end()
            await first.value
            throw error
        }
    }

    @Test @MainActor func endingDuringICEWaitJoinsConnectionTeardown() async throws {
        let room = Room(connectOptions: ConnectOptions(iceTransportPolicy: .relay),
                        roomOptions: RoomOptions(singlePeerConnection: true))
        let session = try makeSession(room: room, preConnectAudio: false)
        session.startupDependencies.makeTrack = { _ in await RTC.run { TestAudioTrack() } }
        let starting = Task { await session.start() }
        do {
            try await poll(timeout: 10, for: "the publisher to wait for ICE") { room._state.transport != nil }
            await session.end()
            await starting.value
            #expect(room.connectionState == .disconnected)
            #expect(room._state.transport == nil)
            #expect(room.localParticipant.trackPublications.isEmpty)
            #expect(session.error == nil)
        } catch {
            starting.cancel()
            await session.end()
            await starting.value
            throw error
        }
    }

    @Test @MainActor func captureFailureClosesReservation() async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        let session = try makeSession(room: room)
        session.startupDependencies.makeTrack = { _ in await RTC.run { TestAudioTrack() } }
        session.startupDependencies.startCapture = { _ in throw LiveKitError(.deviceNotFound) }
        await session.start()
        #expect(session.error != nil)
        #expect(room.connectionState == .disconnected)
        #expect(room._state.transport == nil)
        #expect(room.localParticipant.localAudioTracks.isEmpty)
        await session.end()
    }

    @Test @MainActor func encryptedSessionFallsBackToNormalPublication() async throws {
        let room = Room(roomOptions: RoomOptions(encryptionOptions: EncryptionOptions(keyProvider: BaseKeyProvider()), singlePeerConnection: true))
        let session = try makeSession(room: room)
        let track = await RTC.run { TestAudioTrack() }
        session.startupDependencies.makeTrack = { _ in track }
        await session.start()
        #expect(session.error == nil)
        #expect(room.localParticipant.localAudioTracks.first?.encryptionType == .gcm)
        #expect(track._state.publicationCid == track.mediaTrack.trackId)
        await session.end()
    }

    @Test @MainActor func fullReconnectRepublishesAttachedTrack() async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        let session = try makeSession(room: room, preConnectAudio: false)
        let track = await RTC.run { TestAudioTrack() }
        session.startupDependencies.makeTrack = { _ in track }
        await session.start()
        do {
            #expect(session.error == nil)
            let original = try #require(room.localParticipant.localAudioTracks.first).sid
            let originalCid = try #require(track._state.publicationCid)
            try await room.debug_simulate(scenario: .quickReconnect)
            #expect(room.connectionState == .connected)
            #expect(room.localParticipant.publishedTracksInfo().first?.cid == originalCid)
            #expect(room.localParticipant.localAudioTracks.first?.sid == original)
            try await room.debug_simulate(scenario: .fullReconnect)
            try await poll(timeout: 30, for: "republishing the attached microphone") {
                room.connectionState == .connected && room.localParticipant.localAudioTracks.count == 1
                    && room.localParticipant.localAudioTracks.first?.sid != original
            }
            #expect(room.localParticipant.localAudioTracks.first?.track === track)
            #expect(track._state.publicationCid == track.mediaTrack.trackId)
        } catch {
            await session.end()
            throw error
        }
        await session.end()
    }

    @Test @MainActor func joinReservationDoesNotEnableMicrophoneRTP() async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        let preparation = PreparedAudioPublication(options: AudioPublishOptions())
        let token = try TestEnvironment.liveKitServerToken(for: UUID().uuidString, identity: "reserved", canPublish: true, canPublishData: true)
        do {
            try await room.connect(url: TestEnvironment.liveKitServerUrl(), token: token, preparedAudio: preparation)
            let (context, info) = try #require(try await preparation.sender(in: room))
            #expect(!info.sid.isEmpty)
            await RTC.run {
                #expect(context.sender.raw.track == nil)
                let encodings = context.sender.raw.parameters.encodings
                #expect(!encodings.isEmpty)
                #expect(encodings.allSatisfy { !$0.isActive })
            }
        } catch {
            await room.disconnect()
            await preparation.cancel(in: room)
            throw error
        }
        await room.disconnect()
        await preparation.cancel(in: room)
    }

    @Test @MainActor func completedStartupReleasesItsTaskOwner() async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        var attempt: SessionStartup? = SessionStartup(room: room, preConnectAudio: false)
        weak var weakAttempt = attempt
        let token = try TestEnvironment.liveKitServerToken(for: UUID().uuidString, identity: "ownership", canPublish: true, canPublishData: true)
        var dependencies = SessionStartup.Dependencies()
        dependencies.makeTrack = { _ in await RTC.run { TestAudioTrack() } }
        do {
            _ = try await attempt?.run(preConnectAudio: false, timeout: 10, dependencies: dependencies, fetch: {
                TokenSourceResponse(serverURL: URL(string: TestEnvironment.liveKitServerUrl())!, participantToken: token)
            }, recording: {})
            attempt = nil
            #expect(weakAttempt == nil, "Startup tasks must not retain their owner")
            weakAttempt = nil
        } catch {
            await room.disconnect()
            throw error
        }
        await room.disconnect()
    }

    @MainActor private func makeSession(room: Room, preConnectAudio: Bool = true) throws -> Session {
        let token = try TestEnvironment.liveKitServerToken(for: UUID().uuidString, identity: "session", canPublish: true, canPublishData: true)
        return Session(tokenSource: LiteralTokenSource(serverURL: URL(string: TestEnvironment.liveKitServerUrl())!, participantToken: token),
                       options: SessionOptions(room: room, preConnectAudio: preConnectAudio))
    }
}

/// Models a system permission callback that cannot be cancelled by the caller.
private actor PermissionCallback {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// Models native capture completing inside Track.start() after its task was cancelled.
private final class PermissionDelayedAudioTrack: LocalAudioTrack, @unchecked Sendable {
    let permission = PermissionCallback()
    let stopped = AsyncCompleter<Void>(label: "late capture cleanup", defaultTimeout: 5)
    @RTC init() {
        let native = RTC.createAudioTrack(source: RTC.createAudioSource(nil))
        native.isEnabled = true
        super.init(name: Track.microphoneName, source: .microphone, track: RTCMediaTrack(native),
                   reportStatistics: false, captureOptions: AudioCaptureOptions())
    }

    override func startCapture() async throws { await permission.wait() }
    override func stopCapture() async throws { stopped.resume(returning: ()) }
    override func startWaitingForFrames() async throws {}
}
