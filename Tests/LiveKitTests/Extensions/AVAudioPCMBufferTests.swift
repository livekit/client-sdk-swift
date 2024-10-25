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
@testable import LiveKit
import XCTest

class AVAudioPCMBufferTests: XCTestCase {
    func testResample() {
        // Test case 1: Resample to a higher sample rate
        testResampleHelper(fromSampleRate: 44100, toSampleRate: 48000, expectedSuccess: true)

        // Test case 2: Resample to a lower sample rate
        testResampleHelper(fromSampleRate: 48000, toSampleRate: 16000, expectedSuccess: true)

        // Test case 3: Resample to the same sample rate
        testResampleHelper(fromSampleRate: 44100, toSampleRate: 44100, expectedSuccess: true)

        // Test case 4: Resample to an invalid sample rate
        testResampleHelper(fromSampleRate: 44100, toSampleRate: 0, expectedSuccess: false)
    }

    private func testResampleHelper(fromSampleRate: Double, toSampleRate: Double, expectedSuccess: Bool) {
        // Create a source buffer
        guard let format = AVAudioFormat(standardFormatWithSampleRate: fromSampleRate, channels: 2) else {
            XCTFail("Failed to create audio format")
            return
        }

        let frameCount = 1000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            XCTFail("Failed to create audio buffer")
            return
        }

        // Fill the buffer with some test data
        for frame in 0 ..< frameCount {
            let value = sin(Double(frame) * 2 * .pi / 100.0) // Simple sine wave
            buffer.floatChannelData?[0][frame] = Float(value)
            buffer.floatChannelData?[1][frame] = Float(value)
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        // Perform resampling
        let resampledBuffer = buffer.resample(toSampleRate: toSampleRate)

        if expectedSuccess {
            XCTAssertNotNil(resampledBuffer, "Resampling should succeed")

            if let sampleRate = resampledBuffer?.format.sampleRate {
                XCTAssertTrue(abs(sampleRate - toSampleRate) < 0.001, "Resampled buffer should have the target sample rate")
            } else {
                XCTFail("Resampled buffer's format or sample rate is nil")
            }

            let expectedFrameCount = Int(Double(frameCount) * toSampleRate / fromSampleRate)
            if let resampledFrameLength = resampledBuffer?.frameLength {
                XCTAssertTrue(abs(Int(resampledFrameLength) - expectedFrameCount) <= 1, "Resampled buffer should have the expected frame count")
            } else {
                XCTFail("Resampled buffer's frame length is nil")
            }
        } else {
            XCTAssertNil(resampledBuffer, "Resampling should fail")
        }
    }
}
