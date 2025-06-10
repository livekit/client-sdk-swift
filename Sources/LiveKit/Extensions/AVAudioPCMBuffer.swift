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

import Accelerate
@preconcurrency import AVFoundation

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

        #if swift(>=6.0)
        // Won't be accessed concurrently, marking as nonisolated(unsafe) to avoid Atomics.
        nonisolated(unsafe) var isDone = false
        #else
        var isDone = false
        #endif
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

    /// Convert PCM buffer to specified common format.
    /// Currently supports conversion from Int16 to Float32.
    func convert(toCommonFormat commonFormat: AVAudioCommonFormat) -> AVAudioPCMBuffer? {
        // Check if conversion is needed
        guard format.commonFormat != commonFormat else {
            return self
        }

        // Check if the conversion is supported
        guard format.commonFormat == .pcmFormatInt16, commonFormat == .pcmFormatFloat32 else {
            print("Unsupported conversion: only Int16 to Float32 is supported")
            return nil
        }

        // Create output format
        guard let outputFormat = AVAudioFormat(commonFormat: commonFormat,
                                               sampleRate: format.sampleRate,
                                               channels: format.channelCount,
                                               interleaved: false)
        else {
            print("Failed to create output audio format")
            return nil
        }

        // Create output buffer
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                  frameCapacity: frameCapacity)
        else {
            print("Failed to create output PCM buffer")
            return nil
        }

        outputBuffer.frameLength = frameLength

        let channelCount = Int(format.channelCount)
        let frameCount = Int(frameLength)

        // Ensure the source buffer has Int16 data
        guard let int16Data = int16ChannelData else {
            print("Source buffer doesn't contain Int16 data")
            return nil
        }

        // Ensure the output buffer has Float32 data
        guard let floatData = outputBuffer.floatChannelData else {
            print("Failed to get float channel data from output buffer")
            return nil
        }

        // Convert Int16 to Float32 and normalize to [-1.0, 1.0]
        let scale = Float(Int16.max)
        var scalar = 1.0 / scale

        for channel in 0 ..< channelCount {
            vDSP_vflt16(int16Data[channel], 1, floatData[channel], 1, vDSP_Length(frameCount))
            vDSP_vsmul(floatData[channel], 1, &scalar, floatData[channel], 1, vDSP_Length(frameCount))
        }

        return outputBuffer
    }

    func toData() -> Data? {
        switch format.commonFormat {
        case .pcmFormatInt16:
            guard let channelData = int16ChannelData else { return nil }
            return interleave(channelData: channelData)
        case .pcmFormatInt32:
            guard let channelData = int32ChannelData else { return nil }
            return interleave(channelData: channelData)
        case .pcmFormatFloat32:
            guard let channelData = floatChannelData else { return nil }
            return interleave(channelData: channelData)
        default:
            return nil
        }
    }

    private func interleave<T>(channelData: UnsafePointer<UnsafeMutablePointer<T>>) -> Data {
        let channels = Int(format.channelCount)
        let frameLength = Int(frameLength)
        var interleavedBuffer = [T](repeating: channelData[0][0], count: frameLength * channels)

        for frame in 0 ..< frameLength {
            for channel in 0 ..< channels {
                let channelPtr = channelData[channel]
                interleavedBuffer[frame * channels + channel] = channelPtr[frame]
            }
        }

        return interleavedBuffer.withUnsafeBytes { bufferPointer in
            Data(bufferPointer)
        }
    }
}

extension AVAudioCommonFormat {
    var bytesPerSample: Int {
        switch self {
        case .pcmFormatInt16: return 2
        case .pcmFormatInt32: return 4
        case .pcmFormatFloat32: return 4
        case .pcmFormatFloat64: return 8
        case .otherFormat: return 0
        @unknown default: return 0
        }
    }
}
