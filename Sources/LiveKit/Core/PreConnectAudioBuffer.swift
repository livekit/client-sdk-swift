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
public final class PreConnectAudioBuffer: NSObject, Loggable {
    /// The default data topic used to send the audio buffer.
    @objc
    public static let dataTopic = "lk.agent.pre-connect-audio-buffer"

    /// The room instance to listen for events.
    @objc
    public let room: Room?

    /// The audio recorder instance.
    @objc
    public let recorder: LocalAudioTrackRecorder

    private let state = StateSync<State>(State())
    private struct State {
        var audioStream: LocalAudioTrackRecorder.Stream?
        var timeout: TimeInterval = 10
    }

    /// Initialize the audio buffer with a room instance.
    /// - Parameters:
    ///   - room: The room instance to listen for events.
    @objc
    public init(room: Room?) {
        self.room = room
        let roomOptions = room?._state.roomOptions
        recorder = LocalAudioTrackRecorder(
            track: LocalAudioTrack.createTrack(options: roomOptions?.defaultAudioCaptureOptions.withPreConnect(),
                                               reportStatistics: roomOptions?.reportRemoteTrackStatistics ?? false),
            format: .pcmFormatInt16, // supported by agent plugins
            sampleRate: 24000, // supported by agent plugins
            maxSize: 10 * 1024 * 1024 // arbitrary max recording size of 10MB
        )
        super.init()
    }

    deinit {
        stopRecording()
        room?.remove(delegate: self)
    }

    /// Start capturing audio and listening to ``RoomDelegate`` events.
    /// - Parameters:
    ///   - timeout: The timeout for the remote participant to subscribe to the audio track.
    @objc
    public func startRecording(timeout: TimeInterval = 10) async throws {
        let stream = try await recorder.start()
        log("Started capturing audio", .info)

        state.mutate { state in
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
        guard recorder.isRecording else { return }

        recorder.stop()
        log("Stopped capturing audio", .info)

        if flush, let stream = state.audioStream {
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
        defer {
            room.remove(delegate: self)
        }

        guard let audioStream = state.audioStream else {
            throw LiveKitError(.invalidState, message: "Audio stream is nil")
        }

        let audioData = try await audioStream.collect()
        guard audioData.count > 1024 else {
            throw LiveKitError(.unknown, message: "Audio data size too small, nothing to send")
        }

        let agentIdentities = room.remoteParticipants.filter { _, value in value.kind == .agent }.map(\.key)
        let streamOptions = StreamByteOptions(
            topic: topic,
            attributes: [
                "sampleRate": "\(recorder.sampleRate)",
                "channels": "\(recorder.channels)",
                "trackId": track.stringValue,
            ],
            destinationIdentities: agentIdentities
        )
        let writer = try await room.localParticipant.streamBytes(options: streamOptions)
        try await writer.write(audioData)
        try await writer.close()
        log("Sent audio data", .info)
    }
}
