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

        // Create the AVAudioConverter for resampling.
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            print("Failed to create audio converter.")
            return nil
        }

        // Calculate the frame capacity for the converted buffer.
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let convertedFrameCapacity = AVAudioFrameCount(Double(frameCapacity) * ratio)

        // Create a buffer to hold the converted data.
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: convertedFrameCapacity) else {
            print("Failed to create converted buffer.")
            return nil
        }

        // Perform the conversion.
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return self
        }

        var error: NSError?
        let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if status == .error {
            print("Conversion failed: \(error?.localizedDescription ?? "Unknown error")")
            return nil
        }

        return convertedBuffer
    }
}
