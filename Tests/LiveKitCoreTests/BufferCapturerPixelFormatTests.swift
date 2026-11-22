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

import CoreVideo
@testable import LiveKit
import LiveKitWebRTC
import Testing

@Suite(.tags(.media))
struct BufferCapturerPixelFormatTests {
    @Test(arguments: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange])
    func tenBitBufferResolvesDimensions(format: OSType) async throws {
        let track = await LocalVideoTrack.createBufferTrack(source: .camera)
        let capturer = try #require(track.capturer as? BufferCapturer)
        let buffer = try #require(Self.pixelBuffer(width: 1280, height: 720, format: format))

        capturer.capture(buffer)

        let dimensions = try await capturer.dimensionsCompleter.wait(timeout: 5)
        #expect(dimensions == Dimensions(width: 1280, height: 720))
    }

    @Test func unsupportedBufferIsStillSkipped() async throws {
        let track = await LocalVideoTrack.createBufferTrack(source: .camera)
        let capturer = try #require(track.capturer as? BufferCapturer)
        let buffer = try #require(Self.pixelBuffer(width: 1280, height: 720, format: kCVPixelFormatType_422YpCbCr8))

        capturer.capture(buffer)

        await #expect(throws: (any Error).self) {
            try await capturer.dimensionsCompleter.wait(timeout: 1)
        }
    }

    // WebRTC's own encoders read a 10-bit frame through toI420(): 8-bit planes with each sample's high byte, never unwritten ones.
    @Test(arguments: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange])
    func tenBitBufferReadsAsEightBitI420(format: OSType) throws {
        let source = try #require(Self.pixelBuffer(width: 64, height: 32, format: format))
        Self.fill(source, luma: 940, cb: 512, cr: 300)

        let i420 = TenBitPixelBuffer(pixelBuffer: source).toI420()

        #expect(i420.width == 64 && i420.height == 32)
        #expect(Self.values(i420.dataY, stride: i420.strideY, width: 64, height: 32) == [235])
        #expect(Self.values(i420.dataU, stride: i420.strideU, width: 32, height: 16) == [128])
        #expect(Self.values(i420.dataV, stride: i420.strideV, width: 32, height: 16) == [75])
    }

    // WebRTC's scaling keeps the frame readable: cropped and scaled it is still a TenBitPixelBuffer, and scaled into an NV12
    // buffer, as WebRTC's VideoToolbox encoders do, it writes that buffer.
    @Test func scaledTenBitBufferStaysReadable() throws {
        let source = try #require(Self.pixelBuffer(width: 64, height: 32, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange))
        Self.fill(source, luma: 940, cb: 512, cr: 300)
        let buffer = TenBitPixelBuffer(pixelBuffer: source)

        let half = buffer.cropAndScale(with: 0, offsetY: 0, cropWidth: 64, cropHeight: 32, scaleWidth: 32, scaleHeight: 16)
        #expect(half is TenBitPixelBuffer)
        let i420 = half.toI420()
        #expect(i420.width == 32 && i420.height == 16)
        #expect(Self.values(i420.dataY, stride: i420.strideY, width: 32, height: 16) == [235])

        let output = try #require(Self.pixelBuffer(width: 32, height: 16, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        var temp = [UInt8](repeating: 0, count: Int(buffer.bufferSizeForCroppingAndScaling(toWidth: 32, height: 16)))
        #expect(buffer.cropAndScale(to: output, withTempBuffer: &temp))
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(output, 0)).assumingMemoryBound(to: UInt8.self)
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(output, 1)).assumingMemoryBound(to: UInt8.self)
        #expect(Self.values(luma, stride: Int32(CVPixelBufferGetBytesPerRowOfPlane(output, 0)), width: 32, height: 16) == [235])
        #expect(Self.values(chroma, stride: Int32(CVPixelBufferGetBytesPerRowOfPlane(output, 1)), width: 32, height: 8) == [75, 128])
    }

    /// Every sample of a 10-bit bi-planar buffer set: its 10 bits in the top of its 16, as a camera writes them.
    private static func fill(_ buffer: CVPixelBuffer, luma: UInt16, cb: UInt16, cr: UInt16) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0 ..< 2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            for row in 0 ..< CVPixelBufferGetHeightOfPlane(buffer, plane) {
                let line = (base + row * stride).assumingMemoryBound(to: UInt16.self)
                for column in 0 ..< width {
                    if plane == 0 {
                        line[column] = luma << 6
                    } else {
                        line[2 * column] = cb << 6
                        line[2 * column + 1] = cr << 6
                    }
                }
            }
        }
    }

    /// The distinct values of a plane's visible bytes, in order.
    private static func values(_ data: UnsafePointer<UInt8>, stride: Int32, width: Int, height: Int) -> [UInt8] {
        var seen = Set<UInt8>()
        for row in 0 ..< height {
            for column in 0 ..< width {
                seen.insert(data[row * Int(stride) + column])
            }
        }
        return seen.sorted()
    }

    private static func pixelBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes, &buffer)
        return buffer
    }
}
