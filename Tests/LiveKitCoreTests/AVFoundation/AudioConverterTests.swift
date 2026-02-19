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

@Suite(.tags(.audio)) struct AudioConverterTests {
    @Test func convertFormat() async throws {
        // Sample audio
        let audioDownloadUrl = try #require(URL(string: "https://github.com/rafaelreis-hotmart/Audio-Sample-files/raw/refs/heads/master/sample.wav"))

        print("Downloading sample audio from \(audioDownloadUrl)...")
        let (downloadedLocalUrl, _) = try await URLSession.shared.downloadBackport(from: audioDownloadUrl)

        // Move the file to a new temporary location with a more descriptive name, if desired
        let tempInputUrl = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try FileManager.default.moveItem(at: downloadedLocalUrl, to: tempInputUrl)
        print("Input file: \(tempInputUrl)")

        let inputFile = try AVAudioFile(forReading: tempInputUrl)
        let inputFormat = inputFile.processingFormat // AVAudioFormat object

        print("Sample Rate: \(inputFormat.sampleRate)")
        print("Channel Count: \(inputFormat.channelCount)")
        print("Common Format: \(inputFormat.commonFormat)")
        print("Interleaved: \(inputFormat.isInterleaved)")

        let outputFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))

        let readFrameCapacity: UInt32 = 960
        let inputBuffer = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: readFrameCapacity))

        let converter = try #require(AudioConverter(from: inputFormat, to: outputFormat))

        let tempOutputUrl = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        var outputFile: AVAudioFile? = try AVAudioFile(forWriting: tempOutputUrl, settings: outputFormat.settings)

        while inputFile.framePosition < inputFile.length {
            let framesToRead: UInt32 = min(readFrameCapacity, UInt32(inputFile.length - inputFile.framePosition))
            try inputFile.read(into: inputBuffer, frameCount: framesToRead)
            let buffer = converter.convert(from: inputBuffer)
            print("Converted \(framesToRead) frames from \(inputFormat.sampleRate) to \(outputFormat.sampleRate), outputFrames: \(buffer.frameLength)")
            try outputFile?.write(from: buffer)
        }

        // Close file
        outputFile = nil

        print("Write audio file: \(tempOutputUrl)")

        // Play the recorded file...
        let player = try AVAudioPlayer(contentsOf: tempOutputUrl)
        player.play()
        while player.isPlaying {
            try? await Task.sleep(nanoseconds: 1 * 100_000_000) // 10ms
        }
    }
}
