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

import Combine
import Foundation
@testable import LiveKit
import LiveKitTestSupport
import Testing

@Suite(.serialized, .tags(.e2e), TestLimits.e2e)
struct SessionStartupTests {
    @Test(arguments: [true, false], [true, false])
    @MainActor func joinsBeforeCaptureAndPublishesOnce(singlePC: Bool, preConnectAudio: Bool) async throws {
        let room = Room(connectOptions: ConnectOptions(enableMicrophone: true),
                        roomOptions: RoomOptions(singlePeerConnection: singlePC))
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
            #expect(track._state.rtpSender != nil)
            #expect(room.localParticipant.publishedTracksInfo().first?.cid == track.mediaTrack.trackId)
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

    @Test @MainActor func captureFailureCompletesConnectionTeardownBeforeRetry() async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        let session = try makeSession(room: room)
        session.startupDependencies.makeTrack = { _ in await RTC.run { TestAudioTrack() } }
        session.startupDependencies.startCapture = { _ in throw LiveKitError(.deviceNotFound) }
        await session.start()
        #expect(session.error != nil)
        #expect(room.connectionState == .disconnected)
        #expect(room._state.transport == nil)
        #expect(room.localParticipant.localAudioTracks.isEmpty)
        let retry = await RTC.run { TestAudioTrack() }
        session.startupDependencies.makeTrack = { _ in retry }
        session.startupDependencies.startCapture = { try await $0.start() }
        await session.start()
        #expect(session.error == nil)
        #expect(room.connectionState == .connected)
        #expect(room.localParticipant.localAudioTracks.first?.track === retry)
        await session.end()
    }

    @Test @MainActor func encryptedSessionUsesNormalPublication() async throws {
        let room = Room(roomOptions: RoomOptions(encryptionOptions: EncryptionOptions(keyProvider: BaseKeyProvider()), singlePeerConnection: true))
        let session = try makeSession(room: room)
        let track = await RTC.run { TestAudioTrack() }
        session.startupDependencies.makeTrack = { _ in track }
        await session.start()
        #expect(session.error == nil)
        #expect(room.localParticipant.localAudioTracks.first?.encryptionType == .gcm)
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
            try await room.debug_simulate(scenario: .quickReconnect)
            try await poll(timeout: 30, for: "quick reconnect without republishing") {
                room.connectionState == .connected && room.localParticipant.localAudioTracks.count == 1
                    && room.localParticipant.localAudioTracks.first?.track === track
            }
            let afterQuick = try #require(room.localParticipant.localAudioTracks.first).sid
            #expect(afterQuick == original)
            #expect(room.localParticipant.publishedTracksInfo().first?.cid == track.mediaTrack.trackId)
            try await room.debug_simulate(scenario: .fullReconnect)
            try await poll(timeout: 30, for: "republishing the attached microphone") {
                room.connectionState == .connected && room.localParticipant.localAudioTracks.count == 1
                    && room.localParticipant.localAudioTracks.first?.sid != afterQuick
            }
            #expect(room.localParticipant.localAudioTracks.first?.track === track)
        } catch {
            await session.end()
            throw error
        }
        await session.end()
    }

    @Test @MainActor func quickReconnectBeforePermissionUsesNormalTrackID() async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        let session = try makeSession(room: room, preConnectAudio: false)
        let permission = AsyncCompleter<Void>(label: "pending capture", defaultTimeout: 15)
        let track = await RTC.run { TestAudioTrack() }
        session.startupDependencies.makeTrack = { _ in track }
        session.startupDependencies.startCapture = { track in
            try await permission.wait()
            try await track.start()
        }
        let starting = Task { await session.start() }
        do {
            try await poll(timeout: 10, for: "JOIN before permission") { room.connectionState == .connected }
            let transport = try room.requirePublisher()
            try await room.debug_simulate(scenario: .quickReconnect)
            #expect(try room.requirePublisher() === transport, "A quick reconnect must not fall back to full reconnect")
            #expect(room.localParticipant.localAudioTracks.isEmpty)
            permission.resume(returning: ())
            await starting.value
            #expect(session.error == nil)
            #expect(room.localParticipant.publishedTracksInfo().first?.cid == track.mediaTrack.trackId)
        } catch {
            permission.resume(throwing: CancellationError())
            await session.end()
            await starting.value
            throw error
        }
        await session.end()
    }

    @Test @MainActor func endingDoesNotWaitForAnUncancellableCredentialProvider() async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        var attempt: SessionStartup? = SessionStartup(room: room)
        weak var weakAttempt = attempt
        let permission = PermissionCallback()
        let fetching = AsyncCompleter<Void>(label: "credential callback entered", defaultTimeout: 5)
        let returned = AsyncCompleter<Void>(label: "late credentials returned", defaultTimeout: 5)
        let token = try TestEnvironment.liveKitServerToken(for: UUID().uuidString, identity: "late-credentials", canPublish: true)
        var dependencies = SessionStartup.Dependencies()
        dependencies.makeTrack = { _ in await RTC.run { TestAudioTrack() } }
        let starting = Task {
            try await attempt?.run(preConnectAudio: false, timeout: 10, dependencies: dependencies, fetch: {
                fetching.resume(returning: ())
                await permission.wait()
                returned.resume(returning: ())
                return TokenSourceResponse(serverURL: URL(string: TestEnvironment.liveKitServerUrl())!, participantToken: token)
            }, recording: {})
        }
        try await fetching.wait()
        attempt?.cancel()
        await attempt?.waitForTeardown()
        await #expect(throws: CancellationError.self) { try await starting.value }
        attempt = nil
        #expect(weakAttempt == nil)
        weakAttempt = nil
        #expect(room.connectionState == .disconnected)
        await permission.release()
        try await returned.wait()
        #expect(room.connectionState == .disconnected)
    }

    @Test @MainActor func completedStartupReleasesItsTaskOwner() async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        var attempt: SessionStartup? = SessionStartup(room: room)
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

    @MainActor private func makeSession(room: Room, preConnectAudio: Bool = true, roomName: String = UUID().uuidString) throws -> Session {
        let token = try TestEnvironment.liveKitServerToken(for: roomName, identity: "session", canPublish: true, canPublishData: true)
        return Session(tokenSource: LiteralTokenSource(serverURL: URL(string: TestEnvironment.liveKitServerUrl())!, participantToken: token),
                       options: SessionOptions(room: room, preConnectAudio: preConnectAudio))
    }
}

extension SessionStartupTests {
    @Test @MainActor func existingSubscriberStopsBufferAfterDelayedCapture() async throws {
        try await SessionTestAudioSource.withAudio {
            try await Self.withDelayedBufferPeer()
        }
    }

    private static func withDelayedBufferPeer() async throws {
        let name = UUID().uuidString
        try await TestEnvironment.withRoom(RoomTestingOptions(roomName: name, isE2eeEnabled: false,
                                                              singlePeerConnection: true, canPublishData: true, canSubscribe: true))
        { agent in
            try await Self.checkDelayedBuffer(agent: agent, name: name)
        }
    }

    @MainActor private static func checkDelayedBuffer(agent: Room, name: String) async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        let session = try SessionStartupTests().makeSession(room: room, roomName: name)
        let captured = AsyncCompleter<Void>(label: "delayed microphone permission", defaultTimeout: 10)
        let received = AsyncCompleter<Data>(label: "agent buffer EOF", defaultTimeout: 10)
        try await agent.registerByteStreamHandler(for: PreConnectAudioBuffer.dataTopic) { reader, _ in
            do {
                let data = try await reader.readAll()
                received.resume(returning: data)
            } catch { received.resume(throwing: error) }
        }
        session.startupDependencies.makeTrack = { _ in await RTC.run { TestAudioTrack() } }
        session.startupDependencies.startCapture = { track in
            try await captured.wait()
            try await track.start()
        }
        let starting = Task { await session.start() }
        do {
            try await poll(timeout: 10, for: "room connection before capture") { room.connectionState == .connected }
            let identity = try #require(room.localParticipant.identity)
            try await poll(timeout: 5, for: "subscriber to discover the participant") { agent.remoteParticipants[identity] != nil }
            #expect(agent.remoteParticipants[identity]?.audioTracks.isEmpty == true, "Permission prompts must not expose phantom microphones")
            captured.resume(returning: ())
            await starting.value
            #expect(session.error == nil)
            agent.localParticipant._state.mutate { $0.kind = .agent }
            room.preConnectBuffer.room(room, participant: agent.localParticipant, didUpdateState: .active)
            _ = try await received.wait()
            #expect(room.preConnectBuffer.recorder?.isRecording == false, "Subscription must stop recording before its timeout")
        } catch {
            captured.resume(throwing: CancellationError())
            await session.end()
            await starting.value
            throw error
        }
        await session.end()
    }
}

@MainActor
extension SessionStartupTests {
    @Test func endingAnAlreadyDisconnectedSessionDoesNotPublishAgain() async throws {
        let session = try makeSession(room: Room())
        var changes = 0
        let subscription = session.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        await session.end()
        let afterFirstEnd = changes
        await session.end()
        #expect(changes == afterFirstEnd)
        #expect(session.agent.isFinished)
    }

    @Test func cancelledBeforeRunDoesNotWaitForTeardown() async throws {
        let attempt = SessionStartup(room: Room())
        attempt.cancel()
        await attempt.waitForTeardown()
        await #expect(throws: CancellationError.self) {
            try await attempt.run(preConnectAudio: false, timeout: 5, dependencies: .init(),
                                  fetch: { throw CancellationError() }, recording: {})
        }
        await attempt.waitForTeardown()
    }

    @Test func publishFailureDisconnectsBeforeRetry() async throws {
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        let name = UUID().uuidString
        let token = try TestEnvironment.liveKitServerToken(for: name, identity: "not-allowed", canPublish: false)
        let session = try Session(tokenSource: LiteralTokenSource(serverURL: #require(URL(string: TestEnvironment.liveKitServerUrl())), participantToken: token),
                                  options: SessionOptions(room: room, preConnectAudio: false))
        let track = await RTC.run { TestAudioTrack() }
        session.startupDependencies.makeTrack = { _ in track }
        await session.start()
        #expect(session.error != nil)
        #expect(room.connectionState == .disconnected)
        #expect(room._state.transport == nil)
        #expect(track.trackState == .stopped)
        await session.end()
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
