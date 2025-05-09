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

/// A buffer that captures audio before connecting to the server,
/// and sends it on certain ``RoomDelegate`` events.
@objc
public final class PreConnectAudioBuffer: NSObject, Sendable, Loggable {
    /// The default data topic used to send the audio buffer.
    @objc
    public static let dataTopic = "lk.agent.pre-connect-audio-buffer"

    /// The room instance to listen for events.
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
        var timeout: TimeInterval = 10
    }

    /// Initialize the audio buffer with a room instance.
    /// - Parameters:
    ///   - room: The room instance to listen for events.
    @objc
    public init(room: Room?) {
        state.mutate { $0.room = room }
        super.init()
    }

    deinit {
        stopRecording()
        room?.remove(delegate: self)
    }

    /// Start capturing audio and listening to ``RoomDelegate`` events.
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
            state.timeout = timeout
        }

        room?.add(delegate: self)
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
}

// MARK: - RoomDelegate

extension PreConnectAudioBuffer: RoomDelegate {
    public func roomDidConnect(_: Room) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(state.timeout) * NSEC_PER_SEC)
            stopRecording(flush: true)
        }
    }

    public func room(_ room: Room, participant _: LocalParticipant, remoteDidSubscribeTrack publication: LocalTrackPublication) {
        stopRecording()
        Task {
            do {
                try await sendAudioData(to: room, track: publication.sid)
            } catch {
                log("Unable to send audio: \(error)", .error)
            }
        }
    }

    /// Send the audio data to the room.
    /// - Parameters:
    ///   - room: The room instance to send the audio data.
    ///   - topic: The topic to send the audio data.
    @objc
    public func sendAudioData(to room: Room, track: Track.Sid, on topic: String = dataTopic) async throws {
        let agentIdentities = room.remoteParticipants.filter { _, value in value.kind == .agent }.map(\.key)
        guard !agentIdentities.isEmpty else { return }

        guard let recorder else {
            throw LiveKitError(.invalidState, message: "Recorder is nil")
        }

        guard let audioStream = state.audioStream else {
            throw LiveKitError(.invalidState, message: "Audio stream is nil")
        }

        let audioData = try await audioStream.collect()
        guard audioData.count > 1024 else {
            throw LiveKitError(.unknown, message: "Audio data size too small, nothing to send")
        }

        defer {
            room.remove(delegate: self)
        }

        let streamOptions = StreamByteOptions(
            topic: topic,
            attributes: [
                "sampleRate": "\(recorder.sampleRate)",
                "channels": "\(recorder.channels)",
                "trackId": track.stringValue,
            ],
            destinationIdentities: agentIdentities,
            totalSize: audioData.count
        )
        let writer = try await room.localParticipant.streamBytes(options: streamOptions)
        try await writer.write(audioData)
        try await writer.close()
        log("Sent \(recorder.duration(audioData.count))s = \(audioData.count / 1024)KB of audio data to \(agentIdentities.count) agent(s) ", .info)
    }
}
