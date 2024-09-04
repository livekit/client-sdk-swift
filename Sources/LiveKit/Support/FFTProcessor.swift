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
import Foundation

extension Float {
    /// The Nyquist frequency is sampleRate / 2.
    var nyquistFrequency: Float { self / 2.0 }

    var toDecibels: Float {
        // Avoid log of zero or negative values by using a very small value.
        let minMagnitude: Float = 0.0000001
        return 20 * log10(max(magnitude, minMagnitude))
    }
}

public struct FFTComputeBandsResult {
    let count: Int
    let magnitudes: [Float]
    let frequencies: [Float]
}

public class FFTResult {
    // Result of fft operation.
    public let magnitudes: [Float]

    init(magnitudes: [Float]) {
        self.magnitudes = magnitudes
    }

    // MARK: - Public

    /// Applies logical banding on top of the spectrum data. The bands are spaced linearly throughout the spectrum.
    func computeBands(minFrequency: Float,
                      maxFrequency: Float,
                      bandsCount: Int,
                      sampleRate: Float) -> FFTComputeBandsResult
    {
        let actualMaxFrequency = min(sampleRate.nyquistFrequency, maxFrequency)

        var bandMagnitudes = [Float](repeating: 0.0, count: bandsCount)
        var bandFrequencies = [Float](repeating: 0.0, count: bandsCount)

        let magLowerRange = _magnitudeIndex(for: minFrequency, sampleRate: sampleRate)
        let magUpperRange = _magnitudeIndex(for: actualMaxFrequency, sampleRate: sampleRate)
        let ratio = Float(magUpperRange - magLowerRange) / Float(bandsCount)

        for i in 0 ..< bandsCount {
            let magsStartIdx = Int(floorf(Float(i) * ratio)) + magLowerRange
            let magsEndIdx = Int(floorf(Float(i + 1) * ratio)) + magLowerRange
            var magsAvg: Float
            if magsEndIdx == magsStartIdx {
                // Can happen when numberOfBands < # of magnitudes. No need to average anything.
                magsAvg = magnitudes[magsStartIdx]
            } else {
                magsAvg = _computeAverage(magnitudes, magsStartIdx, magsEndIdx)
            }
            bandMagnitudes[i] = magsAvg
            bandFrequencies[i] = _averageFrequencyInRange(magsStartIdx, magsEndIdx, sampleRate: sampleRate)
        }

        return FFTComputeBandsResult(count: bandsCount,
                                     magnitudes: bandMagnitudes,
                                     frequencies: bandFrequencies)
    }

    // MARK: - Private

    @inline(__always) private func _magnitudeIndex(for frequency: Float, sampleRate: Float) -> Int {
        Int(Float(magnitudes.count) * frequency / sampleRate.nyquistFrequency)
    }

    @inline(__always) private func _computeAverage(_ array: [Float], _ startIdx: Int, _ stopIdx: Int) -> Float {
        var mean: Float = 0
        array.withUnsafeBufferPointer { bufferPtr in
            let ptr = bufferPtr.baseAddress! + startIdx
            vDSP_meanv(ptr, 1, &mean, UInt(stopIdx - startIdx))
        }
        return mean
    }

    /// The average bandwidth throughout the spectrum (nyquist / magnitudes.count)
    @inline(__always) func _computeBandwidth(for sampleRate: Float) -> Float {
        sampleRate.nyquistFrequency / Float(magnitudes.count)
    }

    @inline(__always) private func _averageFrequencyInRange(_ startIndex: Int, _ endIndex: Int, sampleRate: Float) -> Float {
        let bandwidth = _computeBandwidth(for: sampleRate)
        return (bandwidth * Float(startIndex) + bandwidth * Float(endIndex)) / 2
    }
}

class FFTProcessor {
    // MARK: - Public

    public enum WindowType {
        case none
        case hanning
        case hamming
    }

    public let bufferSize: Int

    /// Supplying a window type (hanning or hamming) smooths the edges of the incoming waveform and reduces output errors from the FFT function.
    /// https://en.wikipedia.org/wiki/Spectral_leakage
    public let windowType: WindowType

    // MARK: - Private

    private let bufferHalfSize: Int
    private let bufferLog2Size: Int
    private var window: [Float] = []
    private var fftSetup: FFTSetup

    private var complexBuffer: DSPSplitComplex!
    private var realPointer: UnsafeMutablePointer<Float>
    private var imaginaryPointer: UnsafeMutablePointer<Float>

    init(bufferSize inBufferSize: Int, windowType: WindowType = .hamming) {
        bufferSize = inBufferSize
        self.windowType = windowType
        bufferHalfSize = inBufferSize / 2

        let bufferSizeFloat = Float(inBufferSize)

        // bufferSize must be a power of 2.
        let lg2 = logbf(bufferSizeFloat)
        assert(remainderf(bufferSizeFloat, powf(2.0, lg2)) == 0, "bufferSize must be a power of 2")
        bufferLog2Size = Int(log2f(bufferSizeFloat))

        // Create fft setup.
        fftSetup = vDSP_create_fftsetup(UInt(bufferLog2Size), FFTRadix(FFT_RADIX2))!

        // Allocate memory for the real and imaginary parts.
        realPointer = UnsafeMutablePointer<Float>.allocate(capacity: bufferHalfSize)
        imaginaryPointer = UnsafeMutablePointer<Float>.allocate(capacity: bufferHalfSize)

        // Initialize the memory to zero.
        realPointer.initialize(repeating: 0.0, count: bufferHalfSize)
        imaginaryPointer.initialize(repeating: 0.0, count: bufferHalfSize)

        // Init the complexBuffer.
        complexBuffer = DSPSplitComplex(realp: realPointer, imagp: imaginaryPointer)
    }

    deinit {
        // destroy the fft setup object
        vDSP_destroy_fftsetup(fftSetup)

        realPointer.deallocate()
        imaginaryPointer.deallocate()
    }

    func process(buffer: [Float]) -> FFTResult {
        // Ensure the input buffer is the correct size (twice the half buffer size, since it is interleaved).
        guard buffer.count == bufferSize else {
            fatalError("Input buffer size does not match the initialized buffer size.")
        }

        // Convert the interleaved real and imaginary parts to a split complex form.
        buffer.withUnsafeBufferPointer { bufferPtr in
            let complexPtr = UnsafeRawPointer(bufferPtr.baseAddress!).bindMemory(to: DSPComplex.self, capacity: bufferHalfSize)
            vDSP_ctoz(complexPtr, 2, &complexBuffer, 1, UInt(bufferHalfSize))
        }

        // Perform a forward FFT.
        vDSP_fft_zrip(fftSetup, &complexBuffer, 1, UInt(bufferLog2Size), Int32(FFT_FORWARD))

        // Calculate magnitudes.
        var magnitudes = [Float](repeating: 0.0, count: bufferHalfSize)
        vDSP_zvmags(&complexBuffer, 1, &magnitudes, 1, UInt(bufferHalfSize))

        return FFTResult(magnitudes: magnitudes)
    }
}
