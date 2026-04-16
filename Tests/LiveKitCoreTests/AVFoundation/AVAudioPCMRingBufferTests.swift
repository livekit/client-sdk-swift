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

import AVFAudio
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

#if os(iOS) && targetEnvironment(macCatalyst)
// Required for UnsafeMutableAudioBufferListPointer.
import CoreAudio
#endif

@Suite(.tags(.audio)) struct AVAudioPCMRingBufferTests {
    let format: AVAudioFormat

    init() {
        // Create a standard audio format for testing (44.1kHz, stereo)
        format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    }

    @Test func initialization() {
        let frameCapacity: AVAudioFrameCount = 1024
        let ringBuffer = AVAudioPCMRingBuffer(format: format, frameCapacity: frameCapacity)

        #expect(ringBuffer.capacity == frameCapacity)
        #expect(ringBuffer.buffer.format == format)
        #expect(ringBuffer.buffer.frameCapacity == frameCapacity)
        #expect(ringBuffer.buffer.frameLength == 0)
    }

    @Test func appendAndRead() throws {
        let ringBuffer = AVAudioPCMRingBuffer(format: format, frameCapacity: 1024)

        let testFrames: AVAudioFrameCount = 512
        let testBuffer = try #require(createTestBuffer(frames: testFrames))

        ringBuffer.append(audioBuffer: testBuffer)

        let readBuffer = try #require(ringBuffer.read(frames: testFrames))

        #expect(readBuffer.frameLength == testFrames)
        #expect(compareBuffers(buffer1: testBuffer, buffer2: readBuffer))
    }

    @Test func overflow() throws {
        let capacity: AVAudioFrameCount = 1024
        let ringBuffer = AVAudioPCMRingBuffer(format: format, frameCapacity: capacity)

        let largeBuffer = try #require(createTestBuffer(frames: capacity + 512))

        ringBuffer.append(audioBuffer: largeBuffer)

        #expect(ringBuffer.read(frames: capacity + 512) == nil, "Should not be able to read more frames than capacity")
    }

    @Test func wrapAround() throws {
        let capacity: AVAudioFrameCount = 1024
        let ringBuffer = AVAudioPCMRingBuffer(format: format, frameCapacity: capacity)

        let halfBuffer = try #require(createTestBuffer(frames: capacity / 2))

        ringBuffer.append(audioBuffer: halfBuffer)

        _ = try #require(ringBuffer.read(frames: capacity / 4))

        ringBuffer.append(audioBuffer: halfBuffer)

        let readBuffer = try #require(ringBuffer.read(frames: (capacity / 2) + (capacity / 4)))

        #expect(readBuffer.frameLength == (capacity / 2) + (capacity / 4))
    }

    @Test func emptyBuffer() {
        let ringBuffer = AVAudioPCMRingBuffer(format: format, frameCapacity: 1024)

        // Try to read from empty buffer
        let readBuffer = ringBuffer.read(frames: 512)
        #expect(readBuffer == nil, "Reading from empty buffer should return nil")
    }

    // MARK: - Helper Methods

    private func createTestBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }

        buffer.frameLength = frames

        // Fill buffer with test data
        let bufferList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in bufferList where audioBuffer.mData != nil {
            guard let data = audioBuffer.mData else { continue }

            // Fill with simple pattern (ramp from 0 to 1)
            let floatData = data.assumingMemoryBound(to: Float.self)
            for i in 0 ..< Int(frames) {
                floatData[i] = Float(i) / Float(frames)
            }
        }

        return buffer
    }

    private func compareBuffers(buffer1: AVAudioPCMBuffer, buffer2: AVAudioPCMBuffer) -> Bool {
        guard buffer1.frameLength == buffer2.frameLength else { return false }

        let bufferList1 = UnsafeMutableAudioBufferListPointer(buffer1.mutableAudioBufferList)
        let bufferList2 = UnsafeMutableAudioBufferListPointer(buffer2.mutableAudioBufferList)

        for (buf1, buf2) in zip(bufferList1, bufferList2) {
            guard let data1 = buf1.mData,
                  let data2 = buf2.mData else { continue }

            let floatData1 = data1.assumingMemoryBound(to: Float.self)
            let floatData2 = data2.assumingMemoryBound(to: Float.self)

            for i in 0 ..< Int(buffer1.frameLength) where floatData1[i] != floatData2[i] {
                return false
            }
        }

        return true
    }
}
