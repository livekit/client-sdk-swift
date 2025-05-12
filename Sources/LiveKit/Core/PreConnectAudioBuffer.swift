/*
 * Copyright 2025 LiveKit
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

import AVFAudio
import Foundation

/// A buffer that captures audio before connecting to the server.
@objc
public final class PreConnectAudioBuffer: NSObject, Sendable, Loggable {
    /// The default data topic used to send the audio buffer.
    @objc
    public static let dataTopic = "lk.agent.pre-connect-audio-buffer"

    /// The room instance to send the audio buffer to.
    @objc
    public var room: Room? { state.room }

    /// The audio recorder instance.
    @objc
    public var recorder: LocalAudioTrackRecorder? { state.recorder }

    private let state = StateSync<State>(State())
    private struct State {
        weak var room: Room?
        var recorder: LocalAudioTrackRecorder?
        var audioStream: LocalAudioTrackRecorder.Stream?
        var timeoutTask: Task<Void, Never>?
        var sent: Bool = false
    }

    /// Initialize the audio buffer with a room instance.
    /// - Parameters:
    ///   - room: The room instance to send the audio buffer to.
    @objc
    public init(room: Room?) {
        state.mutate { $0.room = room }
        super.init()
    }

    deinit {
        stopRecording()
    }

    /// Start capturing audio.
    /// - Parameters:
    ///   - timeout: The timeout for the remote participant to subscribe to the audio track.
    ///   - recorder: Optional custom recorder instance. If not provided, a new one will be created.
    @objc
    public func startRecording(timeout: TimeInterval = 10, recorder: LocalAudioTrackRecorder? = nil) async throws {
        let roomOptions = room?._state.roomOptions
        let newRecorder = recorder ?? LocalAudioTrackRecorder(
            track: LocalAudioTrack.createTrack(options: roomOptions?.defaultAudioCaptureOptions,
                                               reportStatistics: roomOptions?.reportRemoteTrackStatistics ?? false),
            format: .pcmFormatInt16, // supported by agent plugins
            sampleRate: 24000, // supported by agent plugins
            maxSize: 10 * 1024 * 1024 // arbitrary max recording size of 10MB
        )

        let stream = try await newRecorder.start()
        log("Started capturing audio", .info)

        state.mutate { state in
            state.recorder = newRecorder
            state.audioStream = stream
            state.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout) * NSEC_PER_SEC)
                self?.stopRecording(flush: true)
            }
            state.sent = false
        }
    }

    /// Stop capturing audio.
    /// - Parameters:
    ///   - flush: If `true`, the audio stream will be flushed immediately without sending.
    @objc
    public func stopRecording(flush: Bool = false) {
        guard let recorder, recorder.isRecording else { return }

        recorder.stop()
        log("Stopped capturing audio", .info)

        if flush, let stream = state.audioStream {
            log("Flushing audio stream", .info)
            Task {
                for await _ in stream {}
            }
        }
    }

    /// Send the audio data to the room.
    /// - Parameters:
    ///   - room: The room instance to send the audio data.
    ///   - agents: The agents to send the audio data to.
    ///   - topic: The topic to send the audio data.
    @objc
    public func sendAudioData(to room: Room, agents: [Participant.Identity], on topic: String = dataTopic) async throws {
        guard !agents.isEmpty else { return }

        guard !state.sent else { return }
        state.mutate { $0.sent = true }

        guard let recorder else {
            log("Skipping preconnect audio, recorder is nil", .info)
            return
        }

        stopRecording()

        guard let audioStream = state.audioStream else {
            throw LiveKitError(.invalidState, message: "Audio stream is nil")
        }

        let audioData = try await audioStream.collect()
        guard audioData.count > 1024 else {
            throw LiveKitError(.unknown, message: "Audio data size too small, nothing to send")
        }

        let streamOptions = StreamByteOptions(
            topic: topic,
            attributes: [
                "sampleRate": "\(recorder.sampleRate)",
                "channels": "\(recorder.channels)",
                "trackId": recorder.track.sid?.stringValue ?? "",
            ],
            destinationIdentities: agents,
            totalSize: audioData.count
        )
        let writer = try await room.localParticipant.streamBytes(options: streamOptions)
        try await writer.write(audioData)
        try await writer.close()
        log("Sent \(recorder.duration(audioData.count))s = \(audioData.count / 1024)KB of audio data to \(agents.count) agent(s) ", .info)
    }
}
