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

import AVFoundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.tags(.audio)) struct AVAudioPCMBufferTests {
    @Test func resample() {
        // Test case 1: Resample to a higher sample rate
        resampleHelper(fromSampleRate: 44100, toSampleRate: 48000, expectedSuccess: true)

        // Test case 2: Resample to a lower sample rate
        resampleHelper(fromSampleRate: 48000, toSampleRate: 16000, expectedSuccess: true)

        // Test case 3: Resample to the same sample rate
        resampleHelper(fromSampleRate: 44100, toSampleRate: 44100, expectedSuccess: true)

        // Test case 4: Resample to an invalid sample rate
        resampleHelper(fromSampleRate: 44100, toSampleRate: 0, expectedSuccess: false)
    }

    private func resampleHelper(fromSampleRate: Double, toSampleRate: Double, expectedSuccess: Bool) {
        // Create a source buffer
        guard let format = AVAudioFormat(standardFormatWithSampleRate: fromSampleRate, channels: 2) else {
            Issue.record("Failed to create audio format")
            return
        }

        let frameCount = 1000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            Issue.record("Failed to create audio buffer")
            return
        }

        fillBufferWithSineWave(buffer: buffer, frameCount: frameCount)

        // Perform resampling
        let resampledBuffer = buffer.resample(toSampleRate: toSampleRate)

        if expectedSuccess {
            #expect(resampledBuffer != nil, "Resampling should succeed")

            if let sampleRate = resampledBuffer?.format.sampleRate {
                #expect(abs(sampleRate - toSampleRate) < 0.001, "Resampled buffer should have the target sample rate")
            } else {
                Issue.record("Resampled buffer's format or sample rate is nil")
            }

            let expectedFrameCount = Int(Double(frameCount) * toSampleRate / fromSampleRate)
            if let resampledFrameLength = resampledBuffer?.frameLength {
                #expect(abs(Int(resampledFrameLength) - expectedFrameCount) <= 1, "Resampled buffer should have the expected frame count")
            } else {
                Issue.record("Resampled buffer's frame length is nil")
            }
        } else {
            #expect(resampledBuffer == nil, "Resampling should fail")
        }
    }

    @Test func toData() {
        let sampleRates: [Double] = [8000, 16000, 22050, 24000, 32000, 44100, 48000]
        let formats: [AVAudioCommonFormat] = [.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32]

        for sampleRate in sampleRates {
            for audioFormat in formats {
                toDataHelper(sampleRate: sampleRate, format: audioFormat)
            }
        }
    }

    private func toDataHelper(sampleRate: Double, format: AVAudioCommonFormat) {
        guard let audioFormat = AVAudioFormat(commonFormat: format,
                                              sampleRate: sampleRate,
                                              channels: 2,
                                              interleaved: false)
        else {
            Issue.record("Failed to create audio format with sample rate \(sampleRate) and format \(format)")
            return
        }

        let frameCount = 1000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            Issue.record("Failed to create audio buffer")
            return
        }

        fillBufferWithSineWave(buffer: buffer, frameCount: frameCount)

        guard let data = buffer.toData() else {
            Issue.record("toData() returned nil for format \(format) at sample rate \(sampleRate)")
            return
        }

        let channels = Int(audioFormat.channelCount)

        let bytesPerSample = switch format {
        case .pcmFormatFloat32:
            4
        case .pcmFormatInt16:
            2
        case .pcmFormatInt32:
            4
        default:
            Int(audioFormat.streamDescription.pointee.mBytesPerFrame) / channels
        }

        let expectedSize = frameCount * channels * bytesPerSample

        #expect(data.count == expectedSize, "Data size mismatch for format \(format) at sample rate \(sampleRate)")

        guard let newBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            Issue.record("Failed to create new buffer")
            return
        }
        newBuffer.frameLength = AVAudioFrameCount(frameCount)

        fillBufferFromData(buffer: newBuffer, data: data)

        #expect(compareBuffers(buffer1: buffer, buffer2: newBuffer),
                "Buffer data mismatch after conversion for format \(format) at sample rate \(sampleRate)")
    }

    private func fillBufferWithSineWave(buffer: AVAudioPCMBuffer, frameCount: Int) {
        let format = buffer.format
        let channels = Int(format.channelCount)

        let sineWaveValues = (0 ..< frameCount).map { frame in
            sin(Double(frame) * 2 * .pi / 100.0)
        }

        for frame in 0 ..< frameCount {
            let value = sineWaveValues[frame]
            for channel in 0 ..< channels {
                switch format.commonFormat {
                case .pcmFormatFloat32:
                    buffer.floatChannelData?[channel][frame] = Float(value)
                case .pcmFormatInt16:
                    buffer.int16ChannelData?[channel][frame] = Int16(value * Double(Int16.max))
                case .pcmFormatInt32:
                    buffer.int32ChannelData?[channel][frame] = Int32(value * Double(Int32.max))
                default:
                    break
                }
            }
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
    }

    private func fillBufferFromData(buffer: AVAudioPCMBuffer, data: Data) {
        let format = buffer.format
        let channels = Int(format.channelCount)
        let frameCount = Int(buffer.frameLength)

        data.withUnsafeBytes { (bufferPointer: UnsafeRawBufferPointer) in
            guard let baseAddress = bufferPointer.baseAddress else { return }

            for frame in 0 ..< frameCount {
                for channel in 0 ..< channels {
                    let index = frame * channels + channel

                    switch format.commonFormat {
                    case .pcmFormatFloat32:
                        let floatArray = baseAddress.assumingMemoryBound(to: Float.self)
                        buffer.floatChannelData?[channel][frame] = floatArray[index]
                    case .pcmFormatInt16:
                        let int16Array = baseAddress.assumingMemoryBound(to: Int16.self)
                        buffer.int16ChannelData?[channel][frame] = int16Array[index]
                    case .pcmFormatInt32:
                        let int32Array = baseAddress.assumingMemoryBound(to: Int32.self)
                        buffer.int32ChannelData?[channel][frame] = int32Array[index]
                    default:
                        break
                    }
                }
            }
        }
    }

    private func compareBuffers(buffer1: AVAudioPCMBuffer, buffer2: AVAudioPCMBuffer) -> Bool {
        guard buffer1.frameLength == buffer2.frameLength,
              buffer1.format.commonFormat == buffer2.format.commonFormat
        else {
            return false
        }

        let channels = Int(buffer1.format.channelCount)
        let frameCount = Int(buffer1.frameLength)
        let format = buffer1.format

        for channel in 0 ..< channels {
            for frame in 0 ..< frameCount {
                let valuesMatch: Bool

                switch format.commonFormat {
                case .pcmFormatFloat32:
                    valuesMatch = buffer1.floatChannelData?[channel][frame] == buffer2.floatChannelData?[channel][frame]
                case .pcmFormatInt16:
                    valuesMatch = buffer1.int16ChannelData?[channel][frame] == buffer2.int16ChannelData?[channel][frame]
                case .pcmFormatInt32:
                    valuesMatch = buffer1.int32ChannelData?[channel][frame] == buffer2.int32ChannelData?[channel][frame]
                default:
                    return false
                }

                if !valuesMatch {
                    return false
                }
            }
        }

        return true
    }
}
