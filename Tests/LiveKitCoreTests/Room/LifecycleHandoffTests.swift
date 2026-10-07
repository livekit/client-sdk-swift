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

/// A teardown in progress must not destroy a session started after it was requested.
@Suite(.serialized, .tags(.networking, .e2e), TestLimits.e2e)
struct LifecycleHandoffTests {
    /// `disconnect()` is held inside its `cleanUp()` (stopping a local track) when the server's
    /// leave for the same session arrives. The app answers `didDisconnectWithError` by connecting
    /// to a new session; once the old `disconnect()` finishes, that session must still be up.
    @Test func connectFromDidDisconnectSurvivesAHeldDisconnect() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(isE2eeEnabled: false, canPublish: true)]) { rooms in
            let room = rooms[0]

            let track = await RTC.run {
                let videoSource = RTC.createVideoSource(forScreenShare: false)
                let capturer = HeldStopCapturer(delegate: videoSource, options: BufferCaptureOptions())
                return LocalVideoTrack(name: "held", source: .camera, capturer: capturer,
                                       videoSource: videoSource, reportStatistics: false)
            }
            let capturer = try #require(track.capturer as? HeldStopCapturer)
            capturer.set(dimensions: Dimensions(width: 320, height: 240))
            try await room.localParticipant.publish(videoTrack: track)

            let token = try TestEnvironment.liveKitServerToken(for: UUID().uuidString,
                                                               identity: "identity-0",
                                                               canPublish: true,
                                                               canPublishData: true,
                                                               canPublishSources: [],
                                                               canSubscribe: true)
            let app = ConnectOnDisconnect(url: TestEnvironment.liveKitServerUrl(), token: token)
            room.add(delegate: app)

            let socket = try #require(await room.signalClient._state.socket)
            let session = try #require(room._state.stage.connection)
            let disconnect = Task { await room.disconnect() }
            try await capturer.stopReached.wait()

            // The server's leave for the old session lands while that teardown is held.
            await room.signalClient(room.signalClient, didReceiveLeave: .disconnect, reason: .clientInitiated, regions: nil,
                                    from: socket, session: session)
            // Delegates run on one serial queue: once this returns, every notification published
            // so far — `didDisconnectWithError` included, if it was published — has been delivered.
            await room.delegates.notifyAsync { _ in }

            // If the room already reported the disconnect, the app's new session comes up first.
            if app.didStart {
                try await app.waitForConnect()
            }
            capturer.release.resume(returning: ())
            await disconnect.value
            try await app.waitForConnect()

            #expect(room.connectionState == .connected, "connectionState: \(room.connectionState)")
            #expect(room._state.sid != nil)
            #expect(room._state.isHandingOff == false)
        }
    }

    /// Interrupted after the JOIN, while the transport is still connecting, `disconnect()` still
    /// leaves: the server reports the participant gone because the client said so.
    @Test func disconnectDuringTheTransportWaitSendsTheLeave() async throws {
        let roomName = UUID().uuidString
        let url = try #require(URL(string: TestEnvironment.liveKitServerUrl()))
        let observer = SignalClient()
        let recorder = SignalRecorder()
        await observer._delegate.set(delegate: recorder)
        try await observer.connect(url, token(roomName, identity: "observer"),
                                   adaptiveStream: false, singlePeerConnection: false)
        await observer.resumeQueues()

        let room = Room()
        // With the offer bundled into the JOIN, `hasPublished` is set right before the transport
        // wait, after the signal queues resumed.
        let inTransportWait = AsyncCompleter<Void>(label: "Waiting for the transport", defaultTimeout: 10)
        let onDidMutate = room._state.onDidMutate
        room._state.onDidMutate = { state, oldState in
            onDidMutate?(state, oldState)
            if state.hasPublished, !oldState.hasPublished { inTransportWait.resume(returning: ()) }
        }
        // Relay-only without a TURN server: the transport never connects.
        let connect = Task {
            try await room.connect(url: url.absoluteString,
                                   token: token(roomName, identity: "interrupted"),
                                   connectOptions: ConnectOptions(primaryTransportConnectTimeout: 60, iceTransportPolicy: .relay),
                                   roomOptions: RoomOptions(singlePeerConnection: true))
        }
        do {
            try await inTransportWait.wait()
            await room.disconnect()
            _ = try? await connect.value

            // Bounded by the server's departure timeout when no leave was sent; not the oracle.
            let reason = try await recorder.participantDisconnected.wait(timeout: 60)
            #expect(reason == .clientInitiated, "reason: \(reason)")
        } catch {
            await observer.cleanUp()
            throw error
        }
        await observer.cleanUp()
    }

    /// The call into the room's leave handler can suspend after the signal client checked the
    /// socket (SE-0338). A leave from a socket replaced by then must not end the session that
    /// replaced it — here a new connect still in its handshake.
    @Test func leaveFromAReplacedSocketDoesNotFailTheNextConnect() async throws {
        let server = try await HeldSocketServer.start()
        defer { server.stop() }

        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            let oldSocket = try #require(await room.signalClient._state.socket)
            let oldSession = try #require(room._state.stage.connection)

            let connect = Task {
                try await room.connect(url: server.url.absoluteString,
                                       token: token(UUID().uuidString, identity: "identity-0"),
                                       connectOptions: ConnectOptions(socketConnectTimeoutInterval: 10))
            }
            try await server.waitForConnection()

            // The old session's leave reaches the room only now, past the signal client's check.
            await room.signalClient(room.signalClient, didReceiveLeave: .disconnect, reason: .duplicateIdentity,
                                    regions: nil, from: oldSocket, session: oldSession)
            #expect(room.connectionState == .connecting, "connectionState: \(room.connectionState)")

            await room.disconnect()
            let error = await #expect(throws: LiveKitError.self) {
                try await connect.value
            }
            #expect(error?.type == .cancelled, "error: \(String(describing: error))")
        }
    }

    /// The leave's socket and its session must be one association: here the session is replaced
    /// while the old socket still reads current (as when a replacement lands between two separate
    /// reads), and the old session's leave must not end the new one.
    @Test func leaveForAReplacedSessionIsIgnoredOnTheSameSocket() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            let socket = try #require(await room.signalClient._state.socket)
            let oldSession = try #require(room._state.stage.connection)
            let (stage, connectionState) = room._state.read { ($0.stage, $0.connectionState) }

            room._state.mutate {
                $0.stage = .connecting(ConnectionDependencies(room: room, roomOptions: RoomOptions()))
                $0.connectionState = .connecting
            }
            await room.signalClient(room.signalClient, didReceiveLeave: .disconnect, reason: .duplicateIdentity,
                                    regions: nil, from: socket, session: oldSession)
            #expect(room.connectionState == .connecting, "connectionState: \(room.connectionState)")

            room._state.mutate {
                $0.stage = stage
                $0.connectionState = connectionState
            }
        }
    }

    /// The microphone track can wait on a permission prompt nobody answers; `disconnect()` must not
    /// wait for it. Interrupted once connected, the room reports the disconnect as `.cancelled`.
    @Test func disconnectDoesNotWaitForTheMicrophone() async throws {
        let room = HeldMicrophoneRoom()
        let delegate = DisconnectRecorder()
        room.add(delegate: delegate)
        let connected = AsyncCompleter<Void>(label: "Connected", defaultTimeout: 10)
        let onDidMutate = room._state.onDidMutate
        room._state.onDidMutate = { state, oldState in
            onDidMutate?(state, oldState)
            if state.connectionState == .connected, oldState.connectionState != .connected { connected.resume(returning: ()) }
        }

        let connect = Task {
            try await room.connect(url: TestEnvironment.liveKitServerUrl(),
                                   token: token(UUID().uuidString, identity: "identity-0"),
                                   connectOptions: ConnectOptions(enableMicrophone: true))
        }
        try await room.microphoneRequested.wait()
        // Connected, and now waiting for the held microphone before publishing it.
        try await connected.wait()

        await room.disconnect()
        #expect(!room.microphoneReturned, "disconnect() waited for the microphone")
        await #expect(throws: (any Error).self) {
            try await connect.value
        }
        await room.delegates.notifyAsync { _ in }
        #expect(delegate.error?.type == .cancelled, "error: \(String(describing: delegate.error))")

        // Permission is granted only now, after the disconnect: the abandoned task must stop
        // before creating or starting any audio.
        room.microphoneRelease.resume(returning: ())
        let outcome = try await room.microphoneOutcome.wait()
        #expect(outcome == "cancelled", "outcome: \(outcome)")
    }

    /// The pre-connect buffer's track is only borrowed by `connect()`: an interrupted connect must
    /// not stop it, or a deferred stop could land on the next session that publishes it.
    @Test func interruptedConnectDoesNotStopThePreConnectTrack() async throws {
        let server = try await HeldSocketServer.start()
        defer { server.stop() }
        let room = Room()
        let track = StopRecordingAudioTrack()
        let recorder = LocalAudioTrackRecorder(track: track,
                                               format: .pcmFormatInt16,
                                               sampleRate: PreConnectAudioBuffer.Constants.sampleRate,
                                               maxSize: PreConnectAudioBuffer.Constants.maxSize)
        try await room.preConnectBuffer.startRecording(timeout: 60, recorder: recorder)
        defer { room.preConnectBuffer.stopRecording(flush: true) }
        // Started, as the next session's publish of it would.
        try await track.start()

        let connect = Task {
            try await room.connect(url: server.url.absoluteString,
                                   token: token(UUID().uuidString, identity: "identity-0"),
                                   connectOptions: ConnectOptions(socketConnectTimeoutInterval: 10))
        }
        try await server.waitForConnection()
        await room.disconnect()
        _ = try? await connect.value

        #expect(!track.didStop, "the interrupted connect stopped the borrowed pre-connect track")
    }

    private func token(_ roomName: String, identity: String) throws -> String {
        try TestEnvironment.liveKitServerToken(for: roomName,
                                               identity: identity,
                                               canPublish: true,
                                               canPublishData: true,
                                               canPublishSources: [],
                                               canSubscribe: true)
    }
}

/// Connects the room to a new session from the first `room(_:didDisconnectWithError:)`.
private final class ConnectOnDisconnect: RoomDelegate, @unchecked Sendable {
    private let url: String
    private let token: String
    private let _didStart = StateSync(false)
    private let _connected = AsyncCompleter<Void>(label: "Connected from didDisconnect", defaultTimeout: 30)

    var didStart: Bool { _didStart.copy() }

    init(url: String, token: String) {
        self.url = url
        self.token = token
    }

    func waitForConnect() async throws {
        try await _connected.wait()
    }

    func room(_ room: Room, didDisconnectWithError _: LiveKitError?) {
        let isFirst = _didStart.mutate { didStart in
            defer { didStart = true }
            return !didStart
        }
        guard isFirst else { return }
        Task.discarding { [url, token, _connected] in
            try await room.connect(url: url, token: token)
            _connected.resume(returning: ())
        }
    }
}

/// A capturer whose stop waits for the test, holding the `cleanUp()` that stops its track.
private final class HeldStopCapturer: BufferCapturer, @unchecked Sendable {
    let stopReached = AsyncCompleter<Void>(label: "Capturer stop reached", defaultTimeout: 30)
    let release = AsyncCompleter<Void>(label: "Capturer stop released", defaultTimeout: 60)

    override func stopCapture() async throws -> Bool {
        stopReached.resume(returning: ())
        try await release.wait()
        return try await super.stopCapture()
    }
}

/// A room whose microphone track waits in its permission request until the test grants it, as
/// when the system prompt goes unanswered.
private final class HeldMicrophoneRoom: Room, @unchecked Sendable {
    let microphone = HeldPermissionAudioTrack()
    /// How the microphone task ended: "cancelled" before touching audio, or what it did instead.
    let microphoneOutcome = AsyncCompleter<String>(label: "Microphone outcome", defaultTimeout: 30)

    var microphoneRequested: AsyncCompleter<Void> { microphone.requested }
    var microphoneRelease: AsyncCompleter<Void> { microphone.release }
    var microphoneReturned: Bool { microphone.returned }

    override func makeMicrophoneTrack() async throws -> LocalTrack {
        do {
            try await microphone.start()
            microphoneOutcome.resume(returning: "started recording")
            return microphone
        } catch {
            microphoneOutcome.resume(returning: error is CancellationError ? "cancelled" : "failed: \(error)")
            throw error
        }
    }
}

/// A microphone track whose permission request, like the system prompt, ignores cancellation and
/// grants once released; everything after it is the real `startCapture()`.
private final class HeldPermissionAudioTrack: LocalAudioTrack, @unchecked Sendable {
    let requested = AsyncCompleter<Void>(label: "Microphone requested", defaultTimeout: 10)
    let release = AsyncCompleter<Void>(label: "Microphone released", defaultTimeout: 30)
    private let _returned = StateSync(false)

    var returned: Bool { _returned.copy() }

    convenience init() {
        let rtcTrack = RTC.createAudioTrack(source: RTC.createAudioSource(nil))
        rtcTrack.isEnabled = true
        self.init(name: Track.microphoneName, source: .microphone, track: RTCMediaTrack(rtcTrack),
                  reportStatistics: false, captureOptions: AudioCaptureOptions())
    }

    override func requestMicrophonePermission() async throws {
        requested.resume(returning: ())
        defer { _returned.mutate { $0 = true } }
        // The timeout only bounds a regression.
        await Task.detached { [release] in try? await release.wait() }.value
    }
}

/// Records the error of `room(_:didDisconnectWithError:)`.
private final class DisconnectRecorder: RoomDelegate, @unchecked Sendable {
    private let _error = StateSync<LiveKitError?>(nil)

    var error: LiveKitError? { _error.copy() }

    func room(_: Room, didDisconnectWithError error: LiveKitError?) {
        _error.mutate { $0 = error }
    }
}

/// A headless audio track that records whether it was stopped.
private final class StopRecordingAudioTrack: LocalAudioTrack, @unchecked Sendable {
    private let _didStop = StateSync(false)

    var didStop: Bool { _didStop.copy() }

    convenience init() {
        let rtcTrack = RTC.createAudioTrack(source: RTC.createAudioSource(nil))
        rtcTrack.isEnabled = true
        self.init(name: Track.microphoneName, source: .microphone, track: RTCMediaTrack(rtcTrack),
                  reportStatistics: false, captureOptions: AudioCaptureOptions())
    }

    override func startCapture() async throws {}
    override func startWaitingForFrames() async throws {}

    override func stopCapture() async throws {
        _didStop.mutate { $0 = true }
    }
}
