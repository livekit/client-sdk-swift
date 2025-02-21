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

import AVFAudio

#if os(iOS) && targetEnvironment(macCatalyst)
// Required for UnsafeMutableAudioBufferListPointer.
import CoreAudio
#endif

class AVAudioPCMRingBuffer {
    let buffer: AVAudioPCMBuffer
    let capacity: AVAudioFrameCount
    private var writeIndex: AVAudioFramePosition = 0
    private var readIndex: AVAudioFramePosition = 0
    private var availableFrames: AVAudioFrameCount = 0

    init(format: AVAudioFormat, frameCapacity: AVAudioFrameCount = 1024 * 10) {
        capacity = frameCapacity
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)!
        buffer.frameLength = 0
        self.buffer = buffer
    }

    func append(audioBuffer srcBuffer: AVAudioPCMBuffer) {
        let framesToCopy = min(srcBuffer.frameLength, capacity - availableFrames) // Prevent overflow

        let sampleSize = buffer.format.streamDescription.pointee.mBytesPerFrame
        let srcPtr = UnsafeMutableAudioBufferListPointer(srcBuffer.mutableAudioBufferList)
        let dstPtr = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        for (src, dst) in zip(srcPtr, dstPtr) {
            guard let srcData = src.mData, let dstData = dst.mData else { continue }

            let firstCopyFrames = min(framesToCopy, capacity - AVAudioFrameCount(writeIndex % AVAudioFramePosition(capacity))) // First segment
            let remainingFrames = framesToCopy - firstCopyFrames // Remaining after wrap

            // First copy
            let dstOffset = Int(writeIndex % AVAudioFramePosition(capacity)) * Int(sampleSize)
            memcpy(dstData.advanced(by: dstOffset), srcData, Int(firstCopyFrames) * Int(sampleSize))

            // Wrap copy if needed
            if remainingFrames > 0 {
                memcpy(dstData, srcData.advanced(by: Int(firstCopyFrames) * Int(sampleSize)), Int(remainingFrames) * Int(sampleSize))
            }
        }

        // Update write index and available frames
        writeIndex = (writeIndex + AVAudioFramePosition(framesToCopy)) % AVAudioFramePosition(capacity)
        availableFrames += framesToCopy
    }

    func read(frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard frames <= availableFrames else { return nil } // Not enough data

        let format = buffer.format
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        outputBuffer.frameLength = frames

        let sampleSize = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let srcPtr = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dstPtr = UnsafeMutableAudioBufferListPointer(outputBuffer.mutableAudioBufferList)

        for (src, dst) in zip(srcPtr, dstPtr) {
            guard let srcData = src.mData, let dstData = dst.mData else { continue }

            let firstReadFrames = min(frames, capacity - AVAudioFrameCount(readIndex % AVAudioFramePosition(capacity))) // First segment
            let remainingFrames = frames - firstReadFrames

            // First copy
            let srcOffset = Int(readIndex % AVAudioFramePosition(capacity)) * sampleSize
            memcpy(dstData, srcData.advanced(by: srcOffset), Int(firstReadFrames) * sampleSize)

            // Wrap copy if needed
            if remainingFrames > 0 {
                memcpy(dstData.advanced(by: Int(firstReadFrames) * sampleSize), srcData, Int(remainingFrames) * sampleSize)
            }
        }

        // Update read index and available frames
        readIndex = (readIndex + AVAudioFramePosition(frames)) % AVAudioFramePosition(capacity)
        availableFrames -= frames

        return outputBuffer
    }
}
