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
import Foundation

#if os(iOS) || os(macOS)

extension RendererProbe {
    /// Writes a high-frequency pattern into the NV12 planes.
    ///
    /// A freshly created `CVPixelBuffer` is zeroed, which renders as flat colour — and two
    /// renders of a flat frame are identical no matter how badly the geometry is wrong. The
    /// fine checkerboard and gradients here are what make a resampling or cropping difference
    /// visible to an image comparison.
    static func fillWithTestPattern(_ pixelBuffer: CVPixelBuffer, pattern: Pattern) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        if let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let bytes = luma.assumingMemoryBound(to: UInt8.self)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    // Diagonal gradient plus an 8px checkerboard, so both low and high
                    // spatial frequencies are present.
                    let gradient = (x * 255 / max(width - 1, 1) + y * 255 / max(height - 1, 1)) / 2
                    let checker = pattern == .gradient ? 0 : (((x / 8) + (y / 8)) % 2 == 0 ? 60 : -60)
                    bytes[y * stride + x] = UInt8(max(0, min(255, gradient + checker)))
                }
            }
        }

        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let bytes = chroma.assumingMemoryBound(to: UInt8.self)
            for y in 0 ..< chromaHeight {
                for x in 0 ..< chromaWidth {
                    bytes[y * stride + x * 2] = UInt8(x * 255 / max(chromaWidth - 1, 1))
                    bytes[y * stride + x * 2 + 1] = UInt8(y * 255 / max(chromaHeight - 1, 1))
                }
            }
        }
    }
}
#endif
