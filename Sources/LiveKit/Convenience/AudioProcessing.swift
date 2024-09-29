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
    static let bufferSize = 1024

    // MARK: - Public

    public let minFrequency: Float
    public let maxFrequency: Float
    public let minDB: Float
    public let maxDB: Float
    public let bandsCount: Int
    public let isCentered: Bool

    public private(set) var bands: [Float]?

    // MARK: - Private

    private let ringBuffer = FloatRingBuffer(size: AudioVisualizeProcessor.bufferSize)
    private let processor: FFTProcessor

    public init(minFrequency: Float = 10,
                maxFrequency: Float = 8000,
                minDB: Float = -32.0,
                maxDB: Float = 32.0,
                bandsCount: Int = 100,
                isCentered: Bool = false)
    {
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.minDB = minDB
        self.maxDB = maxDB
        self.bandsCount = bandsCount
        self.isCentered = isCentered

        processor = FFTProcessor(bufferSize: Self.bufferSize)
    }

    public func add(pcmBuffer: AVAudioPCMBuffer) {
        guard let floatChannelData = pcmBuffer.floatChannelData else { return }

        // Get the float array.
        let floats = Array(UnsafeBufferPointer(start: floatChannelData[0], count: Int(pcmBuffer.frameLength)))
        ringBuffer.write(floats)

        // Get full-size buffer if available, otherwise return
        guard let buffer = ringBuffer.read() else { return }

        // Process FFT and compute frequency bands
        let fftRes = processor.process(buffer: buffer)
        let bands = fftRes.computeBands(
            minFrequency: 0,
            maxFrequency: maxFrequency,
            bandsCount: bandsCount,
            sampleRate: Float(pcmBuffer.format.sampleRate)
        )

        let headroom = maxDB - minDB

        // Normalize magnitudes to decibel ratio using a functional approach
        var normalizedBands = bands.magnitudes.map { magnitude in
            let magnitudeDB = max(0, magnitude.toDecibels + abs(minDB))
            return min(1.0, magnitudeDB / headroom)
        }

        // If centering is enabled, rearrange the normalized bands
        if isCentered {
            // Sort the normalized bands from highest to lowest
            normalizedBands.sort(by: >)

            // Center the sorted bands
            self.bands = centerBands(normalizedBands)
        } else {
            self.bands = normalizedBands
        }
    }

    /// Centers the sorted bands by placing higher values in the middle.
    private func centerBands(_ sortedBands: [Float]) -> [Float] {
        var centeredBands = [Float](repeating: 0, count: sortedBands.count)
        var leftIndex = sortedBands.count / 2
        var rightIndex = leftIndex

        for (index, value) in sortedBands.enumerated() {
            if index % 2 == 0 {
                // Place value to the right
                centeredBands[rightIndex] = value
                rightIndex += 1
            } else {
                // Place value to the left
                leftIndex -= 1
                centeredBands[leftIndex] = value
            }
        }

        return centeredBands
    }
}
