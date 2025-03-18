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
    /// The default participant attribute key used to indicate that the audio buffer is active.
    @objc
    public static let attributeKey = "lk.agent.pre-connect-audio"

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
    }

    /// Initialize the audio buffer with a room instance.
    /// - Parameters:
    ///   - room: The room instance to listen for events.
    ///   - recorder: The audio recorder to use for capturing.
    @objc
    public init(room: Room?,
                recorder: LocalAudioTrackRecorder = LocalAudioTrackRecorder(
                    track: LocalAudioTrack.createTrack(),
                    format: .pcmFormatInt16, // supported by agent plugins
                    sampleRate: 24000, // supported by agent plugins
                    maxSize: 10 * 1024 * 1024 // arbitrary max recording size of 10MB
                ))
    {
        self.room = room
        self.recorder = recorder
        super.init()
    }

    deinit {
        stopRecording()
        room?.remove(delegate: self)
    }

    /// Start capturing audio and listening to ``RoomDelegate`` events.
    @objc
    public func startRecording() async throws {
        room?.add(delegate: self)

        let stream = try await recorder.start()
        log("Started capturing audio", .info)
        state.mutate { state in
            state.audioStream = stream
        }
    }

    /// Stop capturing audio.
    /// - Parameters:
    ///   - flush: If `true`, the audio stream will be flushed immediately without sending.
    @objc
    public func stopRecording(flush: Bool = false) {
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
    public func roomDidConnect(_ room: Room) {
        Task {
            try? await setParticipantAttribute(room: room)
        }
    }

    public func room(_ room: Room, participant _: LocalParticipant, remoteDidSubscribeTrack _: LocalTrackPublication) {
        stopRecording()
        Task {
            try? await sendAudioData(to: room)
        }
    }

    /// Set the participant attribute to indicate that the audio buffer is active.
    /// - Parameters:
    ///   - key: The key to set the attribute.
    ///   - room: The room instance to set the attribute.
    @objc
    public func setParticipantAttribute(key _: String = attributeKey, room: Room) async throws {
        var attributes = room.localParticipant.attributes
        attributes[Self.attributeKey] = "true"
        try await room.localParticipant.set(attributes: attributes)
        log("Set participant attribute", .info)
    }

    /// Send the audio data to the room.
    /// - Parameters:
    ///   - room: The room instance to send the audio data.
    ///   - topic: The topic to send the audio data.
    @objc
    public func sendAudioData(to room: Room, on topic: String = dataTopic) async throws {
        guard let audioStream = state.audioStream else {
            throw LiveKitError(.invalidState, message: "Audio stream is nil")
        }

        let streamOptions = StreamByteOptions(
            topic: topic,
            attributes: [
                "sampleRate": "\(recorder.sampleRate)",
                "channels": "\(recorder.channels)",
            ]
        )
        let writer = try await room.localParticipant.streamBytes(options: streamOptions)
        try await writer.write(audioStream.collect())
        try await writer.close()
        log("Sent audio data", .info)

        room.remove(delegate: self)
    }
}
