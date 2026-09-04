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

import CoreMedia

internal import LiveKitWebRTC

/// A container for the pixel data of a ``VideoFrame``.
///
/// The SDK provides two implementations, ``CVPixelVideoBuffer`` and
/// ``I420VideoBuffer``. Use ``toI420()`` to read planar data regardless of
/// which one a frame arrived with.
public protocol VideoBuffer {}

protocol RTCCompatibleVideoBuffer {
    func toRTCType() -> LKRTCVideoFrameBuffer
}

/// A ``VideoBuffer`` backed by a `CVPixelBuffer`, usually in a native camera
/// format such as bi planar NV12.
public class CVPixelVideoBuffer: VideoBuffer, RTCCompatibleVideoBuffer {
    // Internal RTC type
    private let _rtcType: LKRTCCVPixelBuffer

    /// The underlying pixel buffer.
    public var pixelBuffer: CVPixelBuffer {
        _rtcType.pixelBuffer
    }

    /// Wraps an existing pixel buffer without copying it.
    public init(pixelBuffer: CVPixelBuffer) {
        _rtcType = LKRTCCVPixelBuffer(pixelBuffer: pixelBuffer)
    }

    // Internal only.
    init(rtcCVPixelBuffer: LKRTCCVPixelBuffer) {
        _rtcType = rtcCVPixelBuffer
    }

    func toRTCType() -> LKRTCVideoFrameBuffer {
        _rtcType
    }
}

/// A ``VideoBuffer`` holding I420 planar data, with one full resolution luma
/// plane and two half resolution chroma planes.
public struct I420VideoBuffer: VideoBuffer, RTCCompatibleVideoBuffer {
    // Internal RTC type
    private let _rtcType: any LKRTCI420BufferProtocol

    init(rtcI420Buffer: any LKRTCI420BufferProtocol) {
        _rtcType = rtcI420Buffer
    }

    func toRTCType() -> LKRTCVideoFrameBuffer {
        _rtcType
    }

    /// Converts the planar data to a `CVPixelBuffer`, or returns `nil` if the
    /// conversion fails.
    public func toPixelBuffer() -> CVPixelBuffer? {
        _rtcType.toPixelBuffer()
    }

    /// Width of the luma plane in pixels.
    public var width: Int32 { _rtcType.width }

    /// Height of the luma plane in pixels.
    public var height: Int32 { _rtcType.height }

    /// Width of each chroma plane in pixels, half of ``width`` rounded up.
    public var chromaWidth: Int32 { _rtcType.chromaWidth }

    /// Height of each chroma plane in pixels, half of ``height`` rounded up.
    public var chromaHeight: Int32 { _rtcType.chromaHeight }

    /// Pointer to the start of the luma plane. Valid only while the buffer is alive.
    public var dataY: UnsafePointer<UInt8> { _rtcType.dataY }

    /// Pointer to the start of the U chroma plane. Valid only while the buffer is alive.
    public var dataU: UnsafePointer<UInt8> { _rtcType.dataU }

    /// Pointer to the start of the V chroma plane. Valid only while the buffer is alive.
    public var dataV: UnsafePointer<UInt8> { _rtcType.dataV }

    /// Number of bytes per row of the luma plane, which may exceed ``width``.
    public var strideY: Int32 { _rtcType.strideY }

    /// Number of bytes per row of the U chroma plane.
    public var strideU: Int32 { _rtcType.strideU }

    /// Number of bytes per row of the V chroma plane.
    public var strideV: Int32 { _rtcType.strideV }
}

public extension VideoBuffer {
    /// Converts the buffer to I420 planar format, copying pixel data if the
    /// underlying buffer is not already I420. Returns `nil` if the buffer is
    /// not backed by a format the SDK can convert.
    func toI420() -> I420VideoBuffer? {
        guard let rtcBuffer = self as? RTCCompatibleVideoBuffer else { return nil }
        return I420VideoBuffer(rtcI420Buffer: rtcBuffer.toRTCType().toI420())
    }
}

/// A single raw video frame, either captured locally or received from a remote
/// participant.
public class VideoFrame: NSObject, @unchecked Sendable {
    /// Resolution of the frame, before ``rotation`` is applied.
    public let dimensions: Dimensions

    /// Rotation to apply when rendering the frame.
    public let rotation: VideoRotation

    /// Capture time in nanoseconds, on the system's monotonic clock.
    public let timeStampNs: Int64

    /// The RTP timestamp of this frame in the 90kHz clock used on the wire.
    ///
    /// Assigned by the transport, and distinct from ``timeStampNs``, which is a
    /// capture time in nanoseconds. It is populated for frames handed to a
    /// ``VideoEncoder``, and is 0 for frames the application creates itself.
    public let rtpTimestamp: UInt32

    /// The pixel data of the frame.
    public let buffer: VideoBuffer

    /// Creates a frame without an RTP timestamp, which is set to 0.
    public init(dimensions: Dimensions,
                rotation: VideoRotation,
                timeStampNs: Int64,
                buffer: VideoBuffer)
    {
        self.dimensions = dimensions
        self.rotation = rotation
        self.timeStampNs = timeStampNs
        rtpTimestamp = 0
        self.buffer = buffer
    }

    /// Creates a frame, carrying the RTP timestamp of the stream it belongs to.
    public init(dimensions: Dimensions,
                rotation: VideoRotation,
                timeStampNs: Int64,
                rtpTimestamp: UInt32,
                buffer: VideoBuffer)
    {
        self.dimensions = dimensions
        self.rotation = rotation
        self.timeStampNs = timeStampNs
        self.rtpTimestamp = rtpTimestamp
        self.buffer = buffer
    }
}

extension LKRTCVideoFrame: Loggable {
    func toLKType() -> VideoFrame? {
        let lkBuffer: VideoBuffer

        if let rtcBuffer = buffer as? LKRTCCVPixelBuffer {
            lkBuffer = CVPixelVideoBuffer(rtcCVPixelBuffer: rtcBuffer)
        } else if let rtcI420Buffer = buffer as? any LKRTCI420BufferProtocol {
            lkBuffer = I420VideoBuffer(rtcI420Buffer: rtcI420Buffer)
        } else {
            log("RTCVideoFrame.buffer is not a known type (\(type(of: buffer)))", .error)
            return nil
        }

        return VideoFrame(dimensions: Dimensions(width: width, height: height),
                          rotation: rotation.toLKType(),
                          timeStampNs: timeStampNs,
                          rtpTimestamp: UInt32(bitPattern: timeStamp),
                          buffer: lkBuffer)
    }
}

extension VideoFrame {
    func toRTCType() -> LKRTCVideoFrame {
        // This should never happen
        guard let buffer = buffer as? RTCCompatibleVideoBuffer else { fatalError("Buffer must be a RTCCompatibleVideoBuffer") }

        let rtcFrame = LKRTCVideoFrame(buffer: buffer.toRTCType(),
                                       rotation: rotation.toRTCType(),
                                       timeStampNs: timeStampNs)
        rtcFrame.timeStamp = Int32(bitPattern: rtpTimestamp)
        return rtcFrame
    }
}

public extension VideoFrame {
    /// Converts the frame's buffer to I420 planar format, copying pixel data if
    /// it is not already I420. Returns `nil` if the buffer cannot be converted.
    func toI420() -> I420VideoBuffer? {
        buffer.toI420()
    }

    /// Returns the frame as a `CVPixelBuffer`, converting from I420 if needed.
    func toCVPixelBuffer() -> CVPixelBuffer? {
        if let cvPixelVideoBuffer = buffer as? CVPixelVideoBuffer {
            return cvPixelVideoBuffer.pixelBuffer
        } else if let i420VideoBuffer = buffer as? I420VideoBuffer {
            return i420VideoBuffer.toPixelBuffer()
        }
        return nil
    }

    /// Returns the frame wrapped in a `CMSampleBuffer`.
    func toCMSampleBuffer() -> CMSampleBuffer? {
        guard let cvPixelBuffer = toCVPixelBuffer() else { return nil }
        return CMSampleBuffer.from(cvPixelBuffer)
    }
}
