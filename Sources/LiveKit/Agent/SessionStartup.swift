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

/// Owns concurrent startup without making end() wait for a system permission or credential callback.
@MainActor
final class SessionStartup {
    struct Dependencies: Sendable {
        var makeTrack: @Sendable (Room) async throws -> LocalAudioTrack = { room in
            await LocalAudioTrack.createTrack(options: room._state.roomOptions.defaultAudioCaptureOptions,
                                              reportStatistics: room._state.roomOptions.reportRemoteTrackStatistics)
        }

        var startCapture: @Sendable (LocalAudioTrack) async throws -> Void = { try await $0.start() }
    }

    private enum Event: Sendable {
        case connected(Bool)
        case captured(LocalAudioTrack)
        case published(Bool)
    }

    private struct Inputs: Sendable {
        let credentials = AsyncThrowingStream<TokenSourceResponse, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let capture = AsyncThrowingStream<LocalAudioTrack, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    let room: Room
    private var captureOwner: AnyTaskCancellable?
    private var credentialsOwner: AnyTaskCancellable?
    private var capturedTrack: LocalAudioTrack?
    private var cancelled = false
    private let cancellation = AsyncStream<Void>.makeStream()
    private let finished = AsyncStream<Void>.makeStream()

    init(room: Room) { self.room = room }

    func run(preConnectAudio: Bool, timeout: TimeInterval, dependencies: Dependencies,
             fetch: @escaping @Sendable () async throws -> TokenSourceResponse,
             recording: @escaping @MainActor @Sendable () -> Void) async throws -> Bool
    {
        guard !cancelled else { throw CancellationError() }
        let inputs = startCallbacks(preConnectAudio: preConnectAudio, timeout: timeout,
                                    dependencies: dependencies, fetch: fetch, recording: recording)
        defer {
            captureOwner = nil
            credentialsOwner = nil
            inputs.credentials.continuation.finish()
            inputs.capture.continuation.finish()
            finished.continuation.finish()
        }
        do {
            let dispatchesAgent = try await Self.connectAndPublish(room: room, inputs: inputs,
                                                                   cancellation: cancellation.stream,
                                                                   preConnectAudio: preConnectAudio)
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            capturedTrack = nil
            return dispatchesAgent
        } catch {
            cancel()
            let room = room
            let track = capturedTrack
            capturedTrack = nil
            // Connection children have already finished cleanup. A retry cannot be torn down
            // by an abandoned connection, and cancellation cannot skip stopping owned capture.
            await Task {
                await room.disconnect()
                room.preConnectBuffer.stopRecording(flush: true)
                try? await track?.stop()
            }.value
            throw error
        }
    }

    private func startCallbacks(preConnectAudio: Bool, timeout: TimeInterval,
                                dependencies: Dependencies, fetch: @escaping @Sendable () async throws -> TokenSourceResponse,
                                recording: @escaping @MainActor @Sendable () -> Void) -> Inputs
    {
        let inputs = Inputs()
        let room = room
        let credentials = inputs.credentials
        let capture = inputs.capture
        // These callbacks may ignore cancellation. They only produce results; connection and
        // publication remain in the joined task group below, so late results cannot retry JOIN.
        credentialsOwner = Task {
            do {
                try Task.checkCancellation()
                let response = try await fetch()
                try Task.checkCancellation()
                credentials.continuation.yield(response)
                credentials.continuation.finish()
            } catch { credentials.continuation.finish(throwing: error) }
        }.cancellable()
        captureOwner = Task { [weak self] in
            do {
                let track = try await Self.capture(room: room, preConnectAudio: preConnectAudio,
                                                   timeout: timeout, dependencies: dependencies, recording: recording)
                guard let self, !cancelled else {
                    await Task { try? await track.stop() }.value
                    throw CancellationError()
                }
                capturedTrack = track
                capture.continuation.yield(track)
                capture.continuation.finish()
            } catch { capture.continuation.finish(throwing: error) }
        }.cancellable()
        return inputs
    }

    private static func connectAndPublish(room: Room, inputs: Inputs, cancellation: AsyncStream<Void>,
                                          preConnectAudio: Bool) async throws -> Bool
    {
        try await withThrowingTaskGroup(of: Event.self) { group in
            group.addTask {
                guard let response = try await inputs.credentials.stream.first(where: { _ in true }) else { throw CancellationError() }
                try Task.checkCancellation()
                try await room.connectForSession(url: response.serverURL.absoluteString, token: response.participantToken)
                try Task.checkCancellation()
                return .connected(response.dispatchesAgent())
            }
            group.addTask {
                guard let track = try await inputs.capture.stream.first(where: { _ in true }) else { throw CancellationError() }
                try Task.checkCancellation()
                return .captured(track)
            }
            group.addTask {
                for await _ in cancellation {}
                throw CancellationError()
            }
            var dispatchesAgent: Bool?
            var track: LocalAudioTrack?
            var publishing = false
            for try await event in group {
                switch event {
                case let .connected(value): dispatchesAgent = value
                case let .captured(value): track = value
                case let .published(value):
                    group.cancelAll()
                    return value
                }
                if let dispatchesAgent, let track, !publishing {
                    publishing = true
                    group.addTask {
                        _ = try await room.localParticipant.publish(audioTrack: track,
                                                                    options: room._state.roomOptions.defaultAudioPublishOptions.withPreconnect(preConnectAudio))
                        try Task.checkCancellation()
                        return .published(dispatchesAgent)
                    }
                }
            }
            throw CancellationError()
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
            await Task { try? await track.stop() }.value
            throw error
        }
    }

    func cancel() {
        cancelled = true
        captureOwner?.cancel()
        credentialsOwner?.cancel()
        cancellation.continuation.finish()
    }

    func waitForTeardown() async {
        let finished = finished.stream
        await Task { for await _ in finished {} }.value
    }
}
