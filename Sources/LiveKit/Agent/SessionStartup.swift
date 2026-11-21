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

/// Owns connection and capture separately so a pending permission prompt cannot delay JOIN.
@MainActor
final class SessionStartup {
    struct Dependencies: Sendable {
        var makeTrack: @Sendable (Room) async throws -> LocalAudioTrack = { room in
            await LocalAudioTrack.createTrack(options: room._state.roomOptions.defaultAudioCaptureOptions,
                                              reportStatistics: room._state.roomOptions.reportRemoteTrackStatistics)
        }

        var startCapture: @Sendable (LocalAudioTrack) async throws -> Void = { try await $0.start() }
    }

    let room: Room
    let preparation: PreparedAudioPublication
    private let completion = AsyncCompleter<Bool>(label: "Session.startup", defaultTimeout: 86400)
    private var captureOwner: AnyTaskCancellable?
    private var connectionOwner: AnyTaskCancellable?
    private var driverOwner: AnyTaskCancellable?
    private var cancelled = false
    private let connectionEntered = StateSync(false)
    private let connectionFinished = AsyncCompleter<Void>(label: "Session.connectionFinished", defaultTimeout: 86400)
    private let finished = AsyncCompleter<Void>(label: "Session.startupFinished", defaultTimeout: 86400)

    init(room: Room, preConnectAudio: Bool) {
        self.room = room
        preparation = PreparedAudioPublication(options: room._state.roomOptions.defaultAudioPublishOptions.withPreconnect(preConnectAudio))
    }

    func run(preConnectAudio: Bool, timeout: TimeInterval, dependencies: Dependencies,
             fetch: @escaping @Sendable () async throws -> TokenSourceResponse,
             recording: @escaping @MainActor @Sendable () -> Void) async throws -> Bool
    {
        let room = room
        let preparation = preparation
        let completion = completion
        let connectionEntered = connectionEntered
        let connectionFinished = connectionFinished
        defer { finished.resume(returning: ()) }
        // Credentials begin before media construction, which can cold-start libwebrtc.
        let connecting = Task {
            defer { connectionFinished.resume(returning: ()) }
            let response = try await fetch()
            try Task.checkCancellation()
            connectionEntered.mutate { $0 = true }
            try await room.connect(url: response.serverURL.absoluteString, token: response.participantToken,
                                   preparedAudio: preparation)
            try Task.checkCancellation()
            return response.dispatchesAgent()
        }
        connectionOwner = connecting.cancellable()
        let capturing = Task {
            do {
                return try await Self.capture(room: room, preConnectAudio: preConnectAudio,
                                              timeout: timeout, dependencies: dependencies, recording: recording)
            } catch {
                completion.resume(throwing: error)
                throw error
            }
        }
        captureOwner = capturing.cancellable()
        let driver = Task {
            await Self.publish(room: room, preparation: preparation, connecting: connecting,
                               capturing: capturing, completion: completion)
        }
        driverOwner = driver.cancellable()
        defer {
            captureOwner = nil
            connectionOwner = nil
            driverOwner = nil
        }
        do {
            return try await completion.wait()
        } catch {
            let alreadyCancelled = cancelled
            cancel()
            if !alreadyCancelled {
                await room.disconnect()
                room.preConnectBuffer.stopRecording(flush: true)
            }
            await preparation.cancel(in: room)
            throw error
        }
    }

    private static func capture(room: Room, preConnectAudio: Bool, timeout: TimeInterval,
                                dependencies: Dependencies,
                                recording: @MainActor @Sendable () -> Void) async throws -> LocalAudioTrack
    {
        let track = try await dependencies.makeTrack(room)
        do {
            try Task.checkCancellation()
            try await dependencies.startCapture(track)
            try Task.checkCancellation()
            if preConnectAudio {
                let recorder = LocalAudioTrackRecorder(track: track, format: .pcmFormatInt16,
                                                       sampleRate: PreConnectAudioBuffer.Constants.sampleRate,
                                                       maxSize: PreConnectAudioBuffer.Constants.maxSize)
                try await room.preConnectBuffer.startRecording(timeout: timeout, recorder: recorder)
                try Task.checkCancellation()
            }
            recording()
            return track
        } catch {
            // Track.stop() honors cancellation; cleanup must finish in a fresh task.
            await Task { try? await track.stop() }.value
            throw error
        }
    }

    private static func publish(room: Room, preparation: PreparedAudioPublication,
                                connecting: Task<Bool, any Error>, capturing: Task<LocalAudioTrack, any Error>,
                                completion: AsyncCompleter<Bool>) async
    {
        do {
            let dispatchesAgent = try await connecting.value
            let track = try await capturing.value
            try Task.checkCancellation()
            try await room.localParticipant.publishPreparedAudio(track, preparation: preparation)
            try Task.checkCancellation()
            completion.resume(returning: dispatchesAgent)
        } catch {
            connecting.cancel()
            capturing.cancel()
            // The run() caller owns teardown. A late permission callback cannot
            // disconnect or flush the buffer of a newer attempt on this Room.
            completion.resume(throwing: error)
        }
    }

    func cancel() {
        cancelled = true
        captureOwner?.cancel()
        connectionOwner?.cancel()
        driverOwner?.cancel()
        completion.resume(throwing: CancellationError())
    }

    func waitForTeardown() async {
        try? await finished.wait()
        if connectionEntered.copy() { try? await connectionFinished.wait() }
    }

    func releaseReservation() async { await preparation.cancel(in: room) }
}
