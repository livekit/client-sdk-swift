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
    var nyquistFrequency: Float { self / 2.0 }

    var toDecibels: Float {
        let minMagnitude: Float = 1e-7
        return 20 * log10(max(magnitude, minMagnitude))
    }
}

public struct FFTComputeBandsResult {
    let count: Int
    let magnitudes: [Float]
    let frequencies: [Float]
}

public class FFTResult {
    public let magnitudes: [Float]

    init(magnitudes: [Float]) {
        self.magnitudes = magnitudes
    }

    func computeBands(minFrequency: Float, maxFrequency: Float, bandsCount: Int, sampleRate: Float) -> FFTComputeBandsResult {
        let actualMaxFrequency = min(sampleRate.nyquistFrequency, maxFrequency)
        var bandMagnitudes = [Float](repeating: 0.0, count: bandsCount)
        var bandFrequencies = [Float](repeating: 0.0, count: bandsCount)

        let magLowerRange = _magnitudeIndex(for: minFrequency, sampleRate: sampleRate)
        let magUpperRange = _magnitudeIndex(for: actualMaxFrequency, sampleRate: sampleRate)
        let ratio = Float(magUpperRange - magLowerRange) / Float(bandsCount)

        for i in 0 ..< bandsCount {
            let magsStartIdx = Int(floorf(Float(i) * ratio)) + magLowerRange
            let magsEndIdx = Int(floorf(Float(i + 1) * ratio)) + magLowerRange

            bandMagnitudes[i] = magsEndIdx == magsStartIdx
                ? magnitudes[magsStartIdx]
                : _computeAverage(magnitudes, magsStartIdx, magsEndIdx)

            bandFrequencies[i] = _averageFrequencyInRange(magsStartIdx, magsEndIdx, sampleRate: sampleRate)
        }

        return FFTComputeBandsResult(count: bandsCount, magnitudes: bandMagnitudes, frequencies: bandFrequencies)
    }

    @inline(__always) private func _magnitudeIndex(for frequency: Float, sampleRate: Float) -> Int {
        Int(Float(magnitudes.count) * frequency / sampleRate.nyquistFrequency)
    }

    @inline(__always) private func _computeAverage(_ array: [Float], _ startIdx: Int, _ stopIdx: Int) -> Float {
        var mean: Float = 0
        let count = stopIdx - startIdx
        array.withUnsafeBufferPointer { bufferPtr in
            let ptr = bufferPtr.baseAddress! + startIdx
            vDSP_meanv(ptr, 1, &mean, UInt(count))
        }
        return mean
    }

    @inline(__always) private func _computeBandwidth(for sampleRate: Float) -> Float {
        sampleRate.nyquistFrequency / Float(magnitudes.count)
    }

    @inline(__always) private func _averageFrequencyInRange(_ startIndex: Int, _ endIndex: Int, sampleRate: Float) -> Float {
        let bandwidth = _computeBandwidth(for: sampleRate)
        return (bandwidth * Float(startIndex) + bandwidth * Float(endIndex)) / 2
    }
}

class FFTProcessor {
    public enum WindowType {
        case none
        case hanning
        case hamming
    }

    public enum ScaleType {
        case linear
        case logarithmic
    }

    public let bufferSize: Int
    public let windowType: WindowType
    public let scaleType: ScaleType

    private let bufferHalfSize: Int
    private let bufferLog2Size: Int
    private var window: [Float] = []
    private var fftSetup: FFTSetup
    private var complexBuffer: DSPSplitComplex
    private var realPointer: UnsafeMutablePointer<Float>
    private var imaginaryPointer: UnsafeMutablePointer<Float>

    init(bufferSize: Int, scaleType: ScaleType = .linear, windowType: WindowType = .hanning) {
        self.bufferSize = bufferSize
        self.scaleType = scaleType
        self.windowType = windowType

        bufferHalfSize = bufferSize / 2
        bufferLog2Size = Int(log2f(Float(bufferSize)))

        fftSetup = vDSP_create_fftsetup(UInt(bufferLog2Size), FFTRadix(FFT_RADIX2))!

        realPointer = .allocate(capacity: bufferHalfSize)
        imaginaryPointer = .allocate(capacity: bufferHalfSize)

        realPointer.initialize(repeating: 0.0, count: bufferHalfSize)
        imaginaryPointer.initialize(repeating: 0.0, count: bufferHalfSize)

        complexBuffer = DSPSplitComplex(realp: realPointer, imagp: imaginaryPointer)
        setupWindow()
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        realPointer.deallocate()
        imaginaryPointer.deallocate()
    }

    private func setupWindow() {
        window = [Float](repeating: 1.0, count: bufferSize)
        switch windowType {
        case .none:
            break
        case .hanning:
            vDSP_hann_window(&window, UInt(bufferSize), Int32(vDSP_HANN_NORM))
        case .hamming:
            vDSP_hamm_window(&window, UInt(bufferSize), 0)
        }
    }

    func process(buffer: [Float]) -> FFTResult {
        guard buffer.count == bufferSize else {
            fatalError("Input buffer size mismatch.")
        }

        // Create a new array to hold the windowed buffer
        var windowedBuffer = [Float](repeating: 0.0, count: bufferSize)

        // Multiply the input buffer by the window coefficients
        vDSP_vmul(buffer, 1, window, 1, &windowedBuffer, 1, UInt(bufferSize))

        // Convert the real input to split complex form
        windowedBuffer.withUnsafeBufferPointer { bufferPtr in
            let complexPtr = UnsafeRawPointer(bufferPtr.baseAddress!).bindMemory(to: DSPComplex.self, capacity: bufferHalfSize)
            vDSP_ctoz(complexPtr, 2, &complexBuffer, 1, UInt(bufferHalfSize))
        }

        // Perform the FFT
        vDSP_fft_zrip(fftSetup, &complexBuffer, 1, UInt(bufferLog2Size), Int32(FFT_FORWARD))

        // Calculate magnitudes
        var magnitudes = [Float](repeating: 0.0, count: bufferHalfSize)
        vDSP_zvmags(&complexBuffer, 1, &magnitudes, 1, UInt(bufferHalfSize))

        return FFTResult(magnitudes: magnitudes)
    }
}
