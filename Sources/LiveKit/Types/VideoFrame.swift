/*
 * Copyright 2023 LiveKit
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
import CoreMedia

@_implementationOnly import WebRTC

public protocol VideoBuffer {

}

internal protocol RTCCompatibleVideoBuffer {
    func toRTCType() -> LK_RTCVideoFrameBuffer
}

public class CVPixelVideoBuffer: VideoBuffer, RTCCompatibleVideoBuffer {
    // Internal RTC type
    internal let rtcType: LK_RTCCVPixelBuffer
    internal init(rtcCVPixelBuffer: LK_RTCCVPixelBuffer) {
        self.rtcType = rtcCVPixelBuffer
    }

    func toRTCType() -> LK_RTCVideoFrameBuffer {
        rtcType
    }
}

public struct I420VideoBuffer: VideoBuffer, RTCCompatibleVideoBuffer {
    // Internal RTC type
    internal let rtcType: LK_RTCI420Buffer
    internal init(rtcI420Buffer: LK_RTCI420Buffer) {
        self.rtcType = rtcI420Buffer
    }

    func toRTCType() -> LK_RTCVideoFrameBuffer {
        rtcType
    }
}

public class VideoFrame: NSObject {

    let dimensions: Dimensions
    let rotation: VideoRotation
    let timeStampNs: Int64
    let buffer: VideoBuffer

    // TODO: Implement

    public init(dimensions: Dimensions,
                rotation: VideoRotation,
                timeStampNs: Int64,
                buffer: VideoBuffer) {

        self.dimensions = dimensions
        self.rotation = rotation
        self.timeStampNs = timeStampNs
        self.buffer = buffer
    }
}

internal extension LK_RTCVideoFrame {

    func toLKType() -> VideoFrame? {

        let lkBuffer: VideoBuffer

        if let rtcBuffer = buffer as? LK_RTCCVPixelBuffer {
            lkBuffer = CVPixelVideoBuffer(rtcCVPixelBuffer: rtcBuffer)
        } else if let rtcI420Buffer = buffer as? LK_RTCI420Buffer {
            lkBuffer = I420VideoBuffer(rtcI420Buffer: rtcI420Buffer)
        } else {
            logger.error("RTCVideoFrame.buffer is not a known type (\(type(of: buffer)))")
            return nil
        }

        return VideoFrame(dimensions: Dimensions(width: width, height: height),
                          rotation: rotation.toLKType(),
                          timeStampNs: timeStampNs,
                          buffer: lkBuffer)
    }
}

internal extension VideoFrame {

    func toRTCType() -> LK_RTCVideoFrame {
        // This should never happen
        guard let buffer = buffer as? RTCCompatibleVideoBuffer else { fatalError("Buffer must be a RTCCompatibleVideoBuffer") }

        return LK_RTCVideoFrame(buffer: buffer.toRTCType(),
                                rotation: rotation.toRTCType(),
                                timeStampNs: timeStampNs)
    }
}
