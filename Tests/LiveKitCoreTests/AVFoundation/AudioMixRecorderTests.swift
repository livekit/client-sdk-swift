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
import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

struct AudioMixRecorderTests {
    let audioSettings16k: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    let audioSettings8k: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 8000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    // swiftlint:disable:next function_body_length
    @Test func record() async throws {
        // Sample audio 1
        let audio1Url = try #require(URL(string: "https://github.com/audio-samples/audio-samples.github.io/raw/refs/heads/master/samples/mp3/music/sample-3.mp3"))
        print("Downloading sample audio from \(audio1Url)...")
        let (downloadedLocalUrl1, _) = try await URLSession.shared.downloadBackport(from: audio1Url)
        let audioFile1 = try AVAudioFile(forReading: downloadedLocalUrl1)
        print("Audio file1 format: \(audioFile1.processingFormat)")

        // Sample audio 2
        let audio1Url2 = try #require(URL(string: "https://github.com/audio-samples/audio-samples.github.io/raw/refs/heads/master/samples/mp3/ted_speakers/BillGates/sample-5.mp3"))
        print("Downloading sample audio from \(audio1Url2)...")
        let (downloadedLocalUrl2, _) = try await URLSession.shared.downloadBackport(from: audio1Url2)
        let audioFile2 = try AVAudioFile(forReading: downloadedLocalUrl2)
        print("Audio file2 format: \(audioFile2.processingFormat)")

        let recordFilePath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".aac")
        print("Recording to \(recordFilePath)...")

        var recorder = try AudioMixRecorder(filePath: recordFilePath, audioSettings: audioSettings16k)

        // Sample buffer 1
        let sampleBuffer1 = try #require(AVAudioPCMBuffer(pcmFormat: recorder.processingFormat,
                                                          frameCapacity: AVAudioFrameCount(100)))
        sampleBuffer1.frameLength = 100

        // Record session 1

        print("Record session 1")

        let fileSrc1 = recorder.addSource()
        let fileSrc2 = recorder.addSource()
        let bufferSrc1 = recorder.addSource()

        fileSrc1.scheduleFile(audioFile1)
        fileSrc2.scheduleFile(audioFile2)
        bufferSrc1.scheduleBuffer(sampleBuffer1)

        try recorder.start()

        // Record for 5 seconds...
        try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)

        recorder.stop()

        do {
            // Play the recorded file...
            let player = try AVAudioPlayer(contentsOf: recordFilePath)
            player.prepareToPlay()
            print("Playing audio file, duration: \(player.duration) seconds...")
            #expect(player.play(), "Failed to start audio playback")
            while player.isPlaying {
                try? await Task.sleep(nanoseconds: 1 * 100_000_000) // 10ms
            }
        }

        // Record session 2 (Re-use recorder)

        print("Record session 1")

        // Create new recorder (8k)
        recorder = try AudioMixRecorder(filePath: recordFilePath, audioSettings: audioSettings8k)

        let fileSrc3 = recorder.addSource()
        let fileSrc4 = recorder.addSource()

        fileSrc3.scheduleFile(audioFile1)
        fileSrc4.scheduleFile(audioFile2)

        try recorder.start()

        // Record for 5 seconds...
        try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)

        recorder.stop()

        do {
            // Play the recorded file...
            let player = try AVAudioPlayer(contentsOf: recordFilePath)
            player.prepareToPlay()
            print("Playing audio file, duration: \(player.duration) seconds...")
            #expect(player.play(), "Failed to start audio playback")
            while player.isPlaying {
                try? await Task.sleep(nanoseconds: 1 * 100_000_000) // 10ms
            }
        }
    }

    @Test func scheduleToRemovedSource() async throws {
        let recordFilePath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".aac")
        print("Recording to \(recordFilePath)...")

        let recorder = try AudioMixRecorder(filePath: recordFilePath, audioSettings: audioSettings16k)

        // Sample buffer 1
        let sampleBuffer1 = try #require(AVAudioPCMBuffer(pcmFormat: recorder.processingFormat,
                                                          frameCapacity: AVAudioFrameCount(100)))
        sampleBuffer1.frameLength = 100

        let src1 = recorder.addSource()
        src1.scheduleBuffer(sampleBuffer1)
        try recorder.start()
        let src2 = recorder.addSource()
        // Record for 5 seconds...
        try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)

        recorder.removeAllSources()

        // Schedule after removed
        src1.scheduleBuffer(sampleBuffer1)
        src2.scheduleBuffer(sampleBuffer1)

        recorder.stop()
    }
}
