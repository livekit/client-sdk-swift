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

#if os(iOS)

@testable import LiveKit
import XCTest
import CoreMedia
import AVFAudio

final class BroadcastAudioCodecTests: XCTestCase {
    
    private var codec: BroadcastAudioCodec!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        codec = BroadcastAudioCodec()
    }
    
    func testEncodeDecode() throws {
        let testBuffer = try XCTUnwrap(createTestAudioBuffer(frames: 1024))
        let (metadata, audioData) = try XCTUnwrap(try codec.encode(testBuffer))
        let decodedBuffer = try XCTUnwrap(try codec.decode(audioData, with: metadata))
    }
    
    func testDecodeEmpty() throws {
        let metadata = BroadcastAudioCodec.Metadata(
            sampleCount: 1,
            description: AudioStreamBasicDescription()
        )
        XCTAssertThrowsError(try codec.decode(Data(), with: metadata)) { error in
            XCTAssertEqual(error as? BroadcastAudioCodec.Error, .decodingFailed)
        }
    }
    

    private func createTestAudioBuffer(frames: CMItemCount) -> CMSampleBuffer? {
        // 1. Define the audio format.
        let sampleRate: Float64 = 44100.0
        let channels: UInt32 = 1
        let bitsPerChannel: UInt32 = 16
        let bytesPerFrame: UInt32 = channels * (bitsPerChannel / 8)
        let totalDataSize = Int(frames * CMItemCount(bytesPerFrame))
        
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
        
        // 2. Create a CMAudioFormatDescription from the ASBD.
        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                    asbd: &asbd,
                                                    layoutSize: 0,
                                                    layout: nil,
                                                    magicCookieSize: 0,
                                                    magicCookie: nil,
                                                    extensions: nil,
                                                    formatDescriptionOut: &formatDescription)
        guard status == noErr, let audioFormatDesc = formatDescription else {
            print("Error creating audio format description: \(status)")
            return nil
        }
        
        // 3. Create some dummy PCM data.
        //    (In a real test you would fill this with actual audio sample data.)
        let pcmData = UnsafeMutablePointer<UInt8>.allocate(capacity: totalDataSize)
        // For example purposes we zero-fill the data.
        pcmData.initialize(repeating: 0, count: totalDataSize)
        
        // 4. Wrap the PCM data in a CMBlockBuffer.
        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                    memoryBlock: pcmData,
                                                    blockLength: totalDataSize,
                                                    blockAllocator: kCFAllocatorNull, // We manage pcmData manually.
                                                    customBlockSource: nil,
                                                    offsetToData: 0,
                                                    dataLength: totalDataSize,
                                                    flags: 0,
                                                    blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let cmBlockBuffer = blockBuffer else {
            print("Error creating block buffer: \(status)")
            pcmData.deallocate()
            return nil
        }
        
        // 5. Set up the sample timing.
        //    For constant duration, you can supply a single CMSampleTimingInfo that applies to all frames.
        let frameDuration = CMTimeMake(value: 1, timescale: Int32(sampleRate))
        var timingInfo = CMSampleTimingInfo(duration: frameDuration,
                                            presentationTimeStamp: .zero,
                                            decodeTimeStamp: CMTime.invalid)
        
        // 6. Create the CMSampleBuffer.
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                      dataBuffer: cmBlockBuffer,
                                      dataReady: true,
                                      makeDataReadyCallback: nil,
                                      refcon: nil,
                                      formatDescription: audioFormatDesc,
                                      sampleCount: frames,
                                      sampleTimingEntryCount: 1,
                                      sampleTimingArray: &timingInfo,
                                      sampleSizeEntryCount: 0,  // 0 means the samples are of constant size.
                                      sampleSizeArray: nil,
                                      sampleBufferOut: &sampleBuffer)
        if status != noErr {
            print("Error creating sample buffer: \(status)")
            return nil
        }
        
        // Note: Because we used kCFAllocatorNull for the blockBuffer’s memory allocator,
        // you are responsible for freeing pcmData when it is no longer needed.
        // For testing this is usually acceptable.
        
        return sampleBuffer
    }
    
    /*
    private func createTestAudioBuffer(width: Int, height: Int) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        return pixelBuffer
    }
     */
}

#endif
