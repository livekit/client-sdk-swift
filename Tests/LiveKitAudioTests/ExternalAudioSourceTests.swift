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
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.serialized, .tags(.audio)) struct ExternalAudioSourceTests {
    /// Fills an int16 interleaved buffer with a sine wave.
    private func makeSineBuffer(format: AVAudioFormat, frames: AVAudioFrameCount, frequency: Double = 440) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channels = Int(format.channelCount)
        let data = buffer.int16ChannelData![0]
        for frame in 0 ..< Int(frames) {
            let value = Int16(sin(2.0 * .pi * frequency * Double(frame) / format.sampleRate) * 8000.0)
            for ch in 0 ..< channels {
                data[frame * channels + ch] = value
            }
        }
        return buffer
    }

    /// Fills a float32 deinterleaved buffer with a sine wave, mimicking
    /// ScreenCaptureKit output that requires conversion.
    private func makeFloatSineBuffer(sampleRate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0 ..< Int(channels) {
            let data = buffer.floatChannelData![ch]
            for frame in 0 ..< Int(frames) {
                data[frame] = Float(sin(2.0 * .pi * 440 * Double(frame) / sampleRate) * 0.5)
            }
        }
        return buffer
    }

    @Test func pushAndBufferDrain() async throws {
        let source = try ExternalAudioSource()
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                sampleRate: 48000,
                                                channels: 2,
                                                interleaved: true))

        // 100 ms buffer, capacity is 2x the queue size.
        let buffer = makeSineBuffer(format: format, frames: 4800) // 100 ms
        #expect(source.push(buffer))
        #expect(source.bufferedDurationMs > 0)

        // The 10 ms pacer drains the buffer even with no sinks attached.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(source.bufferedDurationMs == 0)
    }

    @Test func pushConvertsForeignFormats() throws {
        let source = try ExternalAudioSource()

        // Float32 deinterleaved at a different sample rate (SCK-like).
        let buffer = makeFloatSineBuffer(sampleRate: 44100, channels: 2, frames: 1024)
        #expect(source.push(buffer))

        // Mono at declared rate is remixed to the declared channel count.
        let mono = makeFloatSineBuffer(sampleRate: 48000, channels: 1, frames: 480)
        #expect(source.push(mono))
    }

    @Test func pushRejectsOverflow() throws {
        let source = try ExternalAudioSource(options: ExternalAudioSourceOptions(queueSizeMs: 20))
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                sampleRate: 48000,
                                                channels: 2,
                                                interleaved: true))

        // Capacity is 2x queue size (40 ms); a 50 ms push must be rejected.
        let tooBig = makeSineBuffer(format: format, frames: 2400)
        #expect(!source.push(tooBig))

        // A 40 ms push fits.
        let fits = makeSineBuffer(format: format, frames: 1920)
        #expect(source.push(fits))

        source.clearBuffer()
        #expect(source.bufferedDurationMs == 0)
    }

    /// End-to-end: pushed audio reaches a remote participant as an
    /// independent screen-share-audio track, with the ADM never started.
    @Test(.tags(.e2e)) func publishExternalAudioTrack() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true), RoomTestingOptions(canSubscribe: true)]) { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            let publisherIdentity = try #require(room1.localParticipant.identity, "Publisher's identity is nil")
            let remoteParticipant = try #require(room2.remoteParticipants[publisherIdentity], "Failed to lookup Publisher (RemoteParticipant)")

            let source = try ExternalAudioSource()
            let localTrack = LocalAudioTrack.createTrack(externalSource: source)
            #expect(localTrack.source == .screenShareAudio)
            try await room1.localParticipant.publish(audioTrack: localTrack)

            // Keep pushing sine audio while the test observes the remote side.
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 48000,
                                       channels: 2,
                                       interleaved: true)!
            let pushTask = Task {
                while !Task.isCancelled {
                    _ = source.push(makeSineBuffer(format: format, frames: 4800))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            defer { pushTask.cancel() }

            // Wait for the remote track.
            let deadline = Date().addingTimeInterval(30)
            var remoteAudioTrack: RemoteAudioTrack?
            var remotePublication: RemoteTrackPublication?
            while Date() < deadline {
                if let publication = remoteParticipant.audioTracks.first(where: { $0.source == .screenShareAudio }) as? RemoteTrackPublication,
                   let track = publication.track as? RemoteAudioTrack
                {
                    remotePublication = publication
                    remoteAudioTrack = track
                    break
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }

            let track = try #require(remoteAudioTrack, "Remote screen-share-audio track not found within timeout")
            #expect(remotePublication?.source == .screenShareAudio)

            // Wait for audio frames to arrive remotely.
            await confirmation("Did receive audio frame") { confirm in
                let audioFrameWatcher = AudioTrackWatcher(id: "external01") { _ in
                    confirm()
                }
                track.add(audioRenderer: audioFrameWatcher)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                track.remove(audioRenderer: audioFrameWatcher)
            }

            // The headline guarantee: audio flowed remotely while the ADM
            // recording path never started. Playout may be running since the
            // subscribing room shares the process, so only capture state is
            // asserted.
            #expect(!AudioManager.shared.isRecordingInitialized)
            #expect(!AudioManager.shared.isRecording)
        }
    }
}
