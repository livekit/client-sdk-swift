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

            let disconnect = Task { await room.disconnect() }
            try await capturer.stopReached.wait()

            // The server's leave for the old session lands while that teardown is held.
            await room.signalClient(room.signalClient, didReceiveLeave: .disconnect, reason: .clientInitiated, regions: nil)
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
        room._state.onDidMutate = { state, oldState in
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
