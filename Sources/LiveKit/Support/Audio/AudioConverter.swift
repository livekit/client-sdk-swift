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

@preconcurrency import AVFAudio

final class AudioConverter: Sendable {
    let converter: AVAudioConverter
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    let outputBuffer: AVAudioPCMBuffer

    /// Computes required frame capacity for output buffer.
    static func frameCapacity(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat, inputFrameCount: AVAudioFrameCount) -> AVAudioFrameCount {
        let inputSampleRate = inputFormat.sampleRate
        let outputSampleRate = outputFormat.sampleRate
        // Compute the output frame capacity based on sample rate ratio
        return AVAudioFrameCount(Double(inputFrameCount) * (outputSampleRate / inputSampleRate))
    }

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat, outputBufferCapacity: AVAudioFrameCount = 9600) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputBufferCapacity)
        else {
            return nil
        }

        outputBuffer = buffer
        self.converter = converter
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
    }

    func convert(from inputBuffer: AVAudioPCMBuffer) {
        var error: NSError?
        var bufferFilled = false

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if bufferFilled {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            bufferFilled = true
            return inputBuffer
        }
    }
}
