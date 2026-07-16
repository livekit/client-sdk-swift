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

import AVFAudio
import Foundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.serialized, .tags(.audio)) struct PreConnectAudioBufferTests {
    /// Captured audio is sent to the active agent exactly once, with the stream
    /// attributes the agent needs to decode and bind it.
    @Test(.tags(.e2e)) func sendsBufferedAudioWithAttributes() async throws {
        struct ReceivedStream: Sendable {
            let identity: Participant.Identity?
            let attributes: [String: String]
            let data: Data
        }

        try await confirmation("Receives audio data", expectedCount: 1) { confirm in
            try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublish: true, canPublishData: true)]) { rooms in
                let agentRoom = rooms[0]
                let publisherRoom = rooms[1]

                let received = AsyncCompleter<ReceivedStream>(label: "audioStream", defaultTimeout: 15)
                try await agentRoom.registerByteStreamHandler(for: PreConnectAudioBuffer.dataTopic) { reader, participant in
                    confirm()
                    do {
                        try await received.resume(returning: ReceivedStream(identity: participant,
                                                                            attributes: reader.info.attributes,
                                                                            data: reader.readAll()))
                    } catch {
                        received.resume(throwing: error)
                    }
                }

                let buffer = publisherRoom.preConnectBuffer
                let recorder = LocalAudioTrackRecorder(track: TestAudioTrack(),
                                                       format: .pcmFormatInt16,
                                                       sampleRate: PreConnectAudioBuffer.Constants.sampleRate,
                                                       maxSize: PreConnectAudioBuffer.Constants.maxSize)
                try await buffer.startRecording(recorder: recorder)

                // Feed audio into the recorder, as the audio engine would...
                let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                        sampleRate: Double(PreConnectAudioBuffer.Constants.sampleRate),
                                                        channels: 1,
                                                        interleaved: false))
                let pcmBuffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
                pcmBuffer.frameLength = 240
                recorder.render(pcmBuffer: pcmBuffer)

                let publication = try await publisherRoom.localParticipant.publish(audioTrack: recorder.track)

                agentRoom.localParticipant._state.mutate { $0.kind = .agent } // override kind
                buffer.room(publisherRoom, participant: agentRoom.localParticipant, didUpdateState: .active)

                buffer.stopRecording()

                let stream = try await received.wait()
                #expect(stream.identity == publisherRoom.localParticipant.identity)
                #expect(stream.attributes["sampleRate"] == "\(PreConnectAudioBuffer.Constants.sampleRate)")
                #expect(stream.attributes["channels"] == "1")
                #expect(stream.attributes["trackId"] == publication.sid.stringValue)
                #expect(!stream.data.isEmpty, "Received audio data should not be empty")

                // Duplicate triggers (e.g. republish after a reconnect) must not send the buffer again...
                buffer.room(publisherRoom, participant: publisherRoom.localParticipant, didPublishTrack: publication)
                buffer.room(publisherRoom, participant: agentRoom.localParticipant, didUpdateState: .active)

                // Allow a potential duplicate send to surface before confirmation is checked...
                try await Task.sleep(nanoseconds: 500 * NSEC_PER_MSEC)
            }
        }
    }

    /// After the timeout flushes the buffer, a late send is a silent no-op,
    /// so a flush racing the publish trigger never surfaces an error.
    @Test func flushDiscardsBufferSilently() async throws {
        let room = Room()
        let buffer = room.preConnectBuffer
        let recorder = LocalAudioTrackRecorder(track: TestAudioTrack(),
                                               format: .pcmFormatInt16,
                                               sampleRate: PreConnectAudioBuffer.Constants.sampleRate,
                                               maxSize: PreConnectAudioBuffer.Constants.maxSize)
        try await buffer.startRecording(timeout: 1, recorder: recorder)
        #expect(recorder.isRecording)

        // Wait for the recording timeout to flush the buffer...
        let deadline = Date().addingTimeInterval(5)
        while recorder.isRecording, Date() < deadline {
            try await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
        }
        #expect(!recorder.isRecording)

        // Flushed sessions tear down silently: no throw, nothing sent...
        try await buffer.sendAudioData(to: room, trackSid: Track.Sid(from: "TR_test"), agents: [Participant.Identity(from: "agent")])
    }

    /// Sending without an active recorder fails, and an empty agent list is a no-op.
    @Test func sendRequiresActiveRecorder() async throws {
        let room = Room()
        let buffer = PreConnectAudioBuffer(room: room)

        // Empty agent list is a no-op...
        try await buffer.sendAudioData(to: room, trackSid: Track.Sid(from: "TR_test"), agents: [])

        await #expect(throws: LiveKitError.self) {
            try await buffer.sendAudioData(to: room, trackSid: Track.Sid(from: "TR_test"), agents: [Participant.Identity(from: "agent")])
        }
    }

    // MARK: - Bug regressions

    /// The agent can become active before the microphone publish resolves the track sid.
    /// The buffer must still arrive with the published track id, otherwise the agent
    /// cannot bind it and drops the audio.
    @Test(.tags(.e2e), .bug("https://github.com/livekit/client-sdk-swift/issues/1060"))
    func sendsTrackIdWhenAgentActiveBeforePublish() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublish: true, canPublishData: true)]) { rooms in
            let agentRoom = rooms[0]
            let publisherRoom = rooms[1]

            let receivedTrackId = AsyncCompleter<String>(label: "trackId", defaultTimeout: 15)
            try await agentRoom.registerByteStreamHandler(for: PreConnectAudioBuffer.dataTopic) { reader, _ in
                receivedTrackId.resume(returning: reader.info.attributes["trackId"] ?? "")
            }

            let buffer = publisherRoom.preConnectBuffer
            let recorder = LocalAudioTrackRecorder(track: TestAudioTrack(),
                                                   format: .pcmFormatInt16,
                                                   sampleRate: PreConnectAudioBuffer.Constants.sampleRate,
                                                   maxSize: PreConnectAudioBuffer.Constants.maxSize)
            try await buffer.startRecording(recorder: recorder)

            // Agent becomes active before the track is published...
            agentRoom.localParticipant._state.mutate { $0.kind = .agent } // override kind
            buffer.room(publisherRoom, participant: agentRoom.localParticipant, didUpdateState: .active)

            // Let the agent activation land before the publish resolves the track id...
            try await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)

            // Publish resolves the track sid afterwards, as in Room.connect()...
            let publication = try await publisherRoom.localParticipant.publish(audioTrack: recorder.track)
            buffer.stopRecording()

            let trackId = try await receivedTrackId.wait()
            #expect(trackId == publication.sid.stringValue)
        }
    }
}
