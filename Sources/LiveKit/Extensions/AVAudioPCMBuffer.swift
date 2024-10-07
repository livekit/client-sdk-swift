/*
 * Copyright 2024 LiveKit
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

import AVFoundation

public extension AVAudioPCMBuffer {
    func resample(toSampleRate targetSampleRate: Double) -> AVAudioPCMBuffer? {
        let sourceFormat = format

        if sourceFormat.sampleRate == targetSampleRate {
            // Already targetSampleRate.
            return self
        }

        // Define the source format (from the input buffer) and the target format.
        guard let targetFormat = AVAudioFormat(commonFormat: sourceFormat.commonFormat,
                                               sampleRate: targetSampleRate,
                                               channels: sourceFormat.channelCount,
                                               interleaved: sourceFormat.isInterleaved)
        else {
            print("Failed to create target format.")
            return nil
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            print("Failed to create audio converter.")
            return nil
        }

        let capacity = targetFormat.sampleRate * Double(frameLength) / sourceFormat.sampleRate

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(capacity)) else {
            print("Failed to create converted buffer.")
            return nil
        }

        var isDone = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if isDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            isDone = true
            return self
        }

        var error: NSError?
        let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if status == .error {
            print("Conversion failed: \(error?.localizedDescription ?? "Unknown error")")
            return nil
        }

        // Adjust frame length to the actual amount of data written
        convertedBuffer.frameLength = convertedBuffer.frameCapacity

        return convertedBuffer
    }
}
