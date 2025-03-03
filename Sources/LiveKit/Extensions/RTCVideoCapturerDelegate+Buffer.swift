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

import Foundation

#if canImport(ReplayKit)
import ReplayKit
#endif

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

extension FixedWidthInteger {
    func roundUp(toMultipleOf powerOfTwo: Self) -> Self {
        // Check that powerOfTwo really is.
        precondition(powerOfTwo > 0 && powerOfTwo & (powerOfTwo &- 1) == 0)
        // Round up and return. This may overflow and trap, but only if the rounded
        // result would have overflowed anyway.
        return (self + (powerOfTwo &- 1)) & (0 &- powerOfTwo)
    }
}

extension Dimensions {
    // Ensures width and height are even numbers
    func toEncodeSafeDimensions() -> Dimensions {
        Dimensions(width: Swift.max(Self.encodeSafeSize, width.roundUp(toMultipleOf: 2)),
                   height: Swift.max(Self.encodeSafeSize, height.roundUp(toMultipleOf: 2)))
    }

    static func * (a: Dimensions, b: Double) -> Dimensions {
        Dimensions(width: Int32((Double(a.width) * b).rounded()),
                   height: Int32((Double(a.height) * b).rounded()))
    }

    var isRenderSafe: Bool {
        width >= Self.renderSafeSize && height >= Self.renderSafeSize
    }

    var isEncodeSafe: Bool {
        width >= Self.encodeSafeSize && height >= Self.encodeSafeSize
    }
}

extension CGImagePropertyOrientation {
    func toRTCRotation() -> RTCVideoRotation {
        switch self {
        case .up, .upMirrored, .down, .downMirrored: return ._0
        case .left, .leftMirrored: return ._90
        case .right, .rightMirrored: return ._270
        default: return ._0
        }
    }
}

extension CVPixelBuffer {
    func toDimensions() -> Dimensions {
        Dimensions(width: Int32(CVPixelBufferGetWidth(self)),
                   height: Int32(CVPixelBufferGetHeight(self)))
    }
}
