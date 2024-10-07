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

import Accelerate
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

    /// Convert Int16 PCM buffer to Float32 PCM buffer
    func convert(toCommonFormat commonFormat: AVAudioCommonFormat) -> AVAudioPCMBuffer? {
        guard self.format.commonFormat != commonFormat else {
            // Already target format
            return self
        }

        guard case .pcmFormatFloat32 = commonFormat else {
            // Only float32 supported now.
            return nil
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: format.sampleRate,
                                         channels: format.channelCount,
                                         interleaved: false)
        else {
            print("Failed to create Float32 audio format")
            return nil
        }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                                  frameCapacity: frameCapacity)
        else {
            print("Failed to create Float32 PCM buffer")
            return nil
        }

        outputBuffer.frameLength = frameLength

        let channelCount = Int(format.channelCount)
        let frameCount = Int(frameLength)

        // Assuming the current buffer is Int16
        guard let int16Data = int16ChannelData else {
            print("Source buffer is not Int16")
            return nil
        }

        guard let floatData = outputBuffer.floatChannelData else {
            print("Failed to get float channel data")
            return nil
        }

        // Convert Int16 to Float
        let scale = Float(Int16.max)
        for channel in 0 ..< channelCount {
            vDSP_vflt16(int16Data[channel], 1, floatData[channel], 1, vDSP_Length(frameCount))
            var scalar = Float(1.0) / scale
            vDSP_vsmul(floatData[channel], 1, &scalar, floatData[channel], 1, vDSP_Length(frameCount))
        }

        return outputBuffer
    }
}
