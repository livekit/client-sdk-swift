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

@preconcurrency import AVFAudio
@testable import LiveKit

// Used to save audio data for inspecting the correct format, etc.
class TestAudioRecorder: @unchecked Sendable {
    let sampleRate: Double
    let filePath: URL
    private var audioFile: AVAudioFile?

    init(sampleRate: Double = 48000, channels: Int = 1) throws {
        self.sampleRate = sampleRate

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let fileName = UUID().uuidString + ".aac"
        let filePath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
        self.filePath = filePath

        audioFile = try AVAudioFile(forWriting: filePath,
                                    settings: settings,
                                    commonFormat: .pcmFormatInt16,
                                    interleaved: true)
    }

    func write(pcmBuffer: AVAudioPCMBuffer) throws {
        guard let audioFile else { return }
        try audioFile.write(from: pcmBuffer)
    }

    func close() {
        audioFile = nil
    }
}

extension TestAudioRecorder: AudioRenderer {
    func render(pcmBuffer: AVAudioPCMBuffer) {
        try? write(pcmBuffer: pcmBuffer)
    }
}
