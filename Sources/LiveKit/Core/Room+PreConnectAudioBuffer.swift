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
public class PreConnectAudioBuffer: NSObject, Loggable {
    public static let attributeKey = "lk.agent.pre-connect-audio"
    public static let dataTopic = "lk.pre-connect-audio-buffer"

    private let room: Room
    private let autoSend: Bool

    private var recorder: LocalAudioTrackRecorder?
    private var audioStream: LocalAudioTrackRecorder.Stream?

    @objc
    public init(room: Room, autoSend: Bool = true) {
        self.room = room
        self.autoSend = autoSend
        super.init()
        room.add(delegate: self)
    }

    deinit {
        stopRecording()
        room.remove(delegate: self)
    }

    @objc
    public func startRecording() {
        let audioTrack = LocalAudioTrack.createTrack()
        recorder = LocalAudioTrackRecorder(track: audioTrack)
        audioStream = recorder?.start()
        log("Started capturing audio", .info)
    }

    @objc
    public func stopRecording() {
        recorder?.stop()
        log("Stopped capturing audio", .info)
    }

    @objc
    public func setParticipantAttribute() async throws {
        var attributes = room.localParticipant.attributes
        attributes[PreConnectAudioBuffer.attributeKey] = "true"
        try await room.localParticipant.set(attributes: attributes)
        log("Set participant attribute", .info)
    }

    private func sendAudioData() async throws {
        guard let audioStream else { return }
        let writer = try await room.localParticipant.streamBytes(for: Self.dataTopic)
        for await chunk in audioStream {
            try await writer.write(chunk)
        }
        try await writer.close()
        log("Sent audio data", .info)
    }
}

// MARK: - RoomDelegate

extension PreConnectAudioBuffer: RoomDelegate {
    public func roomDidConnect(_: Room) {
        Task {
            try? await setParticipantAttribute()
        }
    }

    public func room(_: Room, participant _: LocalParticipant, remoteDidSubscribeTrack _: LocalTrackPublication) {
        Task {
            stopRecording()
            if autoSend {
                try? await sendAudioData()
            }
        }
    }
}

// MARK: - Convenience

public extension Room {
    func connectWithPreConnectAudioBuffer(
        url: String,
        token: String,
        connectOptions: ConnectOptions? = nil,
        roomOptions: RoomOptions? = nil
    ) async throws {
//        preConnectBuffer.startRecording()

        do {
            try await connect(url: url, token: token, connectOptions: connectOptions, roomOptions: roomOptions)
        } catch {
            preConnectBuffer.stopRecording()
            throw error
        }
    }
}
