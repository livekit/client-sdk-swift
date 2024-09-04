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
import Foundation

public struct AudioLevel {
    /// Linear Scale RMS Value
    public let average: Float
    public let peak: Float
}

public extension LKAudioBuffer {
    /// Convert to AVAudioPCMBuffer float buffer will be normalized to 32 bit.
    @objc
    func toAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
        guard let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: Double(frames * 100),
                                              channels: AVAudioChannelCount(channels),
                                              interleaved: false),
            let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat,
                                             frameCapacity: AVAudioFrameCount(frames))
        else {
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frames)

        guard let targetBufferPointer = pcmBuffer.floatChannelData else { return nil }

        // Optimized version
        let factor = Float(Int16.max)
        var normalizationFactor: Float = 1.0 / factor // Or use 32768.0

        for i in 0 ..< channels {
            vDSP_vsmul(rawBuffer(forChannel: i),
                       1,
                       &normalizationFactor,
                       targetBufferPointer[i],
                       1,
                       vDSP_Length(frames))
        }

        return pcmBuffer
    }
}

public extension AVAudioPCMBuffer {
    /// Computes Peak and Linear Scale RMS Value (Average) for all channels.
    func audioLevels() -> [AudioLevel] {
        var result: [AudioLevel] = []
        guard let data = floatChannelData else {
            // Not containing float data
            return result
        }

        for i in 0 ..< Int(format.channelCount) {
            let channelData = data[i]
            var max: Float = 0.0
            vDSP_maxv(channelData, stride, &max, vDSP_Length(frameLength))
            var rms: Float = 0.0
            vDSP_rmsqv(channelData, stride, &rms, vDSP_Length(frameLength))

            // No conversion to dB, return linear scale values directly
            result.append(AudioLevel(average: rms, peak: max))
        }

        return result
    }
}

public extension Sequence where Iterator.Element == AudioLevel {
    /// Combines all elements into a single audio level by computing the average value of all elements.
    func combine() -> AudioLevel? {
        var count = 0
        let totalSums: (averageSum: Float, peakSum: Float) = reduce((averageSum: 0.0, peakSum: 0.0)) { totals, audioLevel in
            count += 1
            return (totals.averageSum + audioLevel.average,
                    totals.peakSum + audioLevel.peak)
        }

        guard count > 0 else { return nil }

        return AudioLevel(average: totalSums.averageSum / Float(count),
                          peak: totalSums.peakSum / Float(count))
    }
}

public class AudioVisualizeProcessor {
    static let _bufferSize = 1024

    // MARK: - Public

    public let minFrequency: Float
    public let maxFrequency: Float
    public let bandsCount: Int

    public var bands: [Float]?

    // MARK: - Private

    public init(minFrequency: Float = 10, maxFrequency: Float = 8000, bandsCount: Int = 100) {
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.bandsCount = bandsCount
        _processor = FFTProcessor(bufferSize: Self._bufferSize)
    }

    // MARK: - Private

    private let _ringBuffer = FloatRingBuffer(size: _bufferSize)
    private let _processor: FFTProcessor

    public func add(pcmBuffer: AVAudioPCMBuffer) {
        guard let floatChannelData = pcmBuffer.floatChannelData else { return }
        // Get the float array.
        let floats = Array(UnsafeBufferPointer(start: floatChannelData[0], count: Int(pcmBuffer.frameLength)))
        // Write to ring buffer.
        _ringBuffer.write(floats)
        // Get full size buffer if ready, otherwise return for this cycle.
        guard let buffer = _ringBuffer.read() else { return }

        let fftRes = _processor.process(buffer: buffer)
        let bands = fftRes.computeBands(minFrequency: minFrequency,
                                        maxFrequency: maxFrequency,
                                        bandsCount: bandsCount,
                                        sampleRate: Float(pcmBuffer.format.sampleRate))

        let maxDB: Float = 64.0
        let minDB: Float = -32.0
        let headroom = maxDB - minDB

        var result: [Float] = Array(repeating: 0.0, count: bands.magnitudes.count)

        var i = 0
        for magnitude in bands.magnitudes {
            // Incoming magnitudes are linear, making it impossible to see very low or very high values. Decibels to the rescue!
            var magnitudeDB = magnitude.toDecibels

            // Normalize the incoming magnitude so that -Inf = 0
            magnitudeDB = max(0, magnitudeDB + abs(minDB))

            let dbRatio = min(1.0, magnitudeDB / headroom)
            result[i] = dbRatio
            i += 1
        }

        self.bands = result
    }
}
