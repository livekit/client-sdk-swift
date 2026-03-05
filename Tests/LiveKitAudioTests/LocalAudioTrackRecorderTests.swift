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

@Suite(.serialized, .tags(.audio)) struct LocalAudioTrackRecorderTests {
    @Test func recording() async throws {
        let localTrack = LocalAudioTrack.createTrack(options: .noProcessing)

        let recorder = LocalAudioTrackRecorder(
            track: localTrack,
            format: .pcmFormatInt16,
            sampleRate: 48000
        )

        let stream = try await recorder.start()

        try await confirmation("Received audio data") { confirm in
            Task {
                var dataCount = 0
                for await data in stream {
                    dataCount += 1
                    #expect(data.count > 0, "Should have received non-empty audio data")
                    if dataCount >= 10 {
                        confirm()
                        break
                    }
                }
            }

            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        recorder.stop()
    }

    @Test func recordingWithMaxBufferSize() async throws {
        let localTrack = LocalAudioTrack.createTrack(options: .noProcessing)

        let maxBufferSize = 5
        let recorder = LocalAudioTrackRecorder(
            track: localTrack,
            format: .pcmFormatInt16,
            sampleRate: 48000,
            maxSize: maxBufferSize
        )

        let stream = try await recorder.start()

        try await confirmation("Received audio data") { confirm in
            Task {
                var dataCount = 0
                for await _ in stream {
                    dataCount += 1
                    if dataCount >= maxBufferSize * 2 {
                        confirm()
                        break
                    }
                }
            }

            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }

        recorder.stop()
    }

    @Test func multipleRecorders() async throws {
        let localTrack = LocalAudioTrack.createTrack(options: .noProcessing)

        let recorder1 = LocalAudioTrackRecorder(
            track: localTrack,
            format: .pcmFormatInt16,
            sampleRate: 48000
        )

        let recorder2 = LocalAudioTrackRecorder(
            track: localTrack,
            format: .pcmFormatFloat32,
            sampleRate: 16000
        )

        let stream1 = try await recorder1.start()
        let stream2 = try await recorder2.start()

        try await confirmation("Received audio data from recorder1") { confirm1 in
            try await confirmation("Received audio data from recorder2") { confirm2 in
                Task {
                    var dataCount = 0
                    for await _ in stream1 {
                        dataCount += 1
                        if dataCount >= 10 {
                            confirm1()
                            break
                        }
                    }
                }

                Task {
                    var dataCount = 0
                    for await _ in stream2 {
                        dataCount += 1
                        if dataCount >= 10 {
                            confirm2()
                            break
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }

        recorder1.stop()
        recorder2.stop()
    }

    @Test func objCCompatibility() async throws {
        let localTrack = LocalAudioTrack.createTrack(options: .noProcessing)

        let recorder = LocalAudioTrackRecorder(
            track: localTrack,
            format: .pcmFormatInt16,
            sampleRate: 48000
        )

        try await confirmation("Received audio data") { dataConfirm in
            try await confirmation("Completion called") { completionConfirm in
                recorder.start(onData: { _ in
                    dataConfirm()
                }, onCompletion: { _ in
                    completionConfirm()
                })

                try? await Task.sleep(nanoseconds: 5_000_000_000)

                recorder.stop()

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}
