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
@testable import LiveKit
import XCTest

final class AudioMixRecorderTests: XCTestCase {
    func testRecord() async throws {
        // Sample audio 1
        let audio1Url = URL(string: "https://github.com/audio-samples/audio-samples.github.io/raw/refs/heads/master/samples/mp3/music/sample-3.mp3")!
        print("Downloading sample audio from \(audio1Url)...")
        let (downloadedLocalUrl1, _) = try await URLSession.shared.downloadBackport(from: audio1Url)
        let audioFile1 = try AVAudioFile(forReading: downloadedLocalUrl1)
        print("Audio file1 format: \(audioFile1.processingFormat)")

        // Sample audio 2
        let audio1Url2 = URL(string: "https://github.com/audio-samples/audio-samples.github.io/raw/refs/heads/master/samples/mp3/ted_speakers/BillGates/sample-6.mp3")!
        print("Downloading sample audio from \(audio1Url2)...")
        let (downloadedLocalUrl2, _) = try await URLSession.shared.downloadBackport(from: audio1Url2)
        let audioFile2 = try AVAudioFile(forReading: downloadedLocalUrl2)
        print("Audio file2 format: \(audioFile2.processingFormat)")

        let recordFileName = UUID().uuidString + ".aac"
        let recordFilePath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(recordFileName)
        print("Recording to \(recordFilePath)...")

        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let recorder = try AudioMixRecorder(format: format)

        try recorder.start(filePath: recordFilePath)

        let src1 = recorder.addSource()
        Task {
            await src1.playerNode.scheduleFile(audioFile1, at: nil)
        }
        src1.playerNode.play()

        let src2 = recorder.addSource()
        Task {
            await src2.playerNode.scheduleFile(audioFile2, at: nil)
        }
        src2.playerNode.play()

        // Record for 5 seconds...
        try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
        recorder.stop()
    }
}
