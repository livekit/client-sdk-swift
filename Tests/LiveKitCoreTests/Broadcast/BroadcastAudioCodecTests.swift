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

#if os(iOS)

import AVFAudio
import CoreMedia
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.tags(.broadcast))
struct BroadcastAudioCodecTests {
    private let codec = BroadcastAudioCodec()

    @Test func encodeDecode() throws {
        let testBuffer = try #require(createTestAudioBuffer())

        let (metadata, audioData) = try codec.encode(testBuffer)
        let decodedBuffer = try codec.decode(audioData, with: metadata)

        #expect(decodedBuffer.frameLength == AVAudioFrameCount(testBuffer.numSamples))

        let asbd = try #require(testBuffer.formatDescription?.audioStreamBasicDescription)
        #expect(decodedBuffer.format.streamDescription.pointee == asbd)
    }

    @Test func decodeEmpty() throws {
        let metadata = BroadcastAudioCodec.Metadata(
            sampleCount: 1,
            description: AudioStreamBasicDescription()
        )
        #expect(throws: BroadcastAudioCodec.Error.decodingFailed) {
            try codec.decode(Data(), with: metadata)
        }
    }

    // swiftlint:disable:next function_body_length
    private func createTestAudioBuffer() -> CMSampleBuffer? {
        let frames = 1024
        let sampleRate: Float64 = 44100.0
        let channels: UInt32 = 1
        let bitsPerChannel: UInt32 = 16
        let bytesPerFrame = channels * (bitsPerChannel / 8)
        let totalDataSize = Int(frames) * Int(bytesPerFrame)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bitsPerChannel,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr,
            let audioFormatDesc = formatDescription else { return nil }

        let pcmData = UnsafeMutablePointer<UInt8>.allocate(capacity: totalDataSize)
        pcmData.initialize(repeating: 0, count: totalDataSize)

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: pcmData,
            blockLength: totalDataSize,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalDataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr,
            let cmBlockBuffer = blockBuffer
        else {
            pcmData.deallocate()
            return nil
        }

        var timingInfo = CMSampleTimingInfo(
            duration: CMTimeMake(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: CMTime.invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: cmBlockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: audioFormatDesc,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        return sampleBuffer
    }
}

extension AudioStreamBasicDescription: Swift.Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate &&
            lhs.mFormatID == rhs.mFormatID &&
            lhs.mFormatFlags == rhs.mFormatFlags &&
            lhs.mBytesPerPacket == rhs.mBytesPerPacket &&
            lhs.mFramesPerPacket == rhs.mFramesPerPacket &&
            lhs.mBytesPerFrame == rhs.mBytesPerFrame &&
            lhs.mChannelsPerFrame == rhs.mChannelsPerFrame &&
            lhs.mBitsPerChannel == rhs.mBitsPerChannel &&
            lhs.mReserved == rhs.mReserved
    }
}

#endif
