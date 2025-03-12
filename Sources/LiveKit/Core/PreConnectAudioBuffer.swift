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

@objc
public final class PreConnectAudioBuffer: NSObject, Loggable {
    @objc
    public static let attributeKey = "lk.agent.pre-connect-audio"
    @objc
    public static let dataTopic = "lk.agent.pre-connect-audio-buffer"

    @objc
    public let room: Room?

    @objc
    public let recorder: LocalAudioTrackRecorder

    private let state = StateSync<State>(State())
    private struct State {
        var audioStream: LocalAudioTrackRecorder.Stream?
    }

    @objc
    public init(room: Room?,
                recorder: LocalAudioTrackRecorder = LocalAudioTrackRecorder(
                    track: LocalAudioTrack.createTrack(),
                    format: .pcmFormatInt16,
                    sampleRate: 24000,
                    maxSize: 10_000_000
                ))
    {
        self.room = room
        self.recorder = recorder
        super.init()
        room?.add(delegate: self)
    }

    deinit {
        stopRecording()
        room?.remove(delegate: self)
    }

    @objc
    public func startRecording() async {
        let stream = recorder.start()
        log("Started capturing audio", .info)
        state.mutate { state in
            state.audioStream = stream
        }
    }

    @objc
    public func stopRecording() {
        recorder.stop()
        log("Stopped capturing audio", .info)
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

    @objc
    public func setParticipantAttribute(room: Room) async throws {
        var attributes = room.localParticipant.attributes
        attributes[Self.attributeKey] = "true"
        try await room.localParticipant.set(attributes: attributes)
        log("Set participant attribute", .info)
    }

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

        for await chunk in audioStream {
            try await writer.write(chunk)
        }

        try await writer.close()
        log("Sent audio data", .info)
    }
}
