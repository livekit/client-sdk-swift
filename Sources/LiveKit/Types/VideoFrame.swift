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

import CoreMedia
import Foundation

@_implementationOnly import WebRTC

public protocol VideoBuffer {}

protocol RTCCompatibleVideoBuffer {
    func toRTCType() -> LKRTCVideoFrameBuffer
}

public class CVPixelVideoBuffer: VideoBuffer, RTCCompatibleVideoBuffer {
    // Internal RTC type
    let rtcType: LKRTCCVPixelBuffer
    init(rtcCVPixelBuffer: LKRTCCVPixelBuffer) {
        rtcType = rtcCVPixelBuffer
    }

    func toRTCType() -> LKRTCVideoFrameBuffer {
        rtcType
    }
}

public struct I420VideoBuffer: VideoBuffer, RTCCompatibleVideoBuffer {
    // Internal RTC type
    let rtcType: LKRTCI420Buffer
    init(rtcI420Buffer: LKRTCI420Buffer) {
        rtcType = rtcI420Buffer
    }

    func toRTCType() -> LKRTCVideoFrameBuffer {
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
                buffer: VideoBuffer)
    {
        self.dimensions = dimensions
        self.rotation = rotation
        self.timeStampNs = timeStampNs
        self.buffer = buffer
    }
}

extension LKRTCVideoFrame {
    func toLKType() -> VideoFrame? {
        let lkBuffer: VideoBuffer

        if let rtcBuffer = buffer as? LKRTCCVPixelBuffer {
            lkBuffer = CVPixelVideoBuffer(rtcCVPixelBuffer: rtcBuffer)
        } else if let rtcI420Buffer = buffer as? LKRTCI420Buffer {
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

extension VideoFrame {
    func toRTCType() -> LKRTCVideoFrame {
        // This should never happen
        guard let buffer = buffer as? RTCCompatibleVideoBuffer else { fatalError("Buffer must be a RTCCompatibleVideoBuffer") }

        return LKRTCVideoFrame(buffer: buffer.toRTCType(),
                               rotation: rotation.toRTCType(),
                               timeStampNs: timeStampNs)
    }
}
