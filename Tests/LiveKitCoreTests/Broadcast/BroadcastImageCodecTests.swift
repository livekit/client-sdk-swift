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

import CoreVideo
import Foundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.tags(.broadcast))
struct BroadcastImageCodecTests {
    private let codec = BroadcastImageCodec()

    @Test func encodeDecode() throws {
        let (width, height) = (64, 32)
        let testBuffer = try #require(createTestPixelBuffer(width: width, height: height))

        let (metadata, imageData) = try codec.encode(testBuffer)
        #expect(metadata.width == width)
        #expect(metadata.height == height)
        #expect(imageData.count > 0)

        let decodedBuffer = try codec.decode(imageData, with: metadata)
        #expect(CVPixelBufferGetWidth(decodedBuffer) == width)
        #expect(CVPixelBufferGetHeight(decodedBuffer) == height)
    }

    @Test func decodeNonImageData() throws {
        let nonImageData = Data(repeating: 0xFA, count: 1024)
        let metadata = BroadcastImageCodec.Metadata(width: 100, height: 100)
        #expect(throws: BroadcastImageCodec.Error.decodingFailed) {
            try codec.decode(nonImageData, with: metadata)
        }
    }

    @Test func decodeEmpty() throws {
        let metadata = BroadcastImageCodec.Metadata(width: 100, height: 100)
        #expect(throws: BroadcastImageCodec.Error.decodingFailed) {
            try codec.decode(Data(), with: metadata)
        }
    }

    private func createTestPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
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
}

#endif
