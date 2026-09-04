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

import Foundation

internal import LiveKitWebRTC

/// An encoded frame produced by a custom ``VideoEncoder`` and delivered
/// to the SDK via ``VideoEncoderCallback``.
public struct EncodedVideoFrame: Sendable {
    /// The role of a frame within the encoded stream.
    public enum FrameType: Sendable {
        case empty
        case key
        case delta
    }

    /// The kind of content carried by the frame.
    public enum ContentType: Sendable {
        case unspecified
        case screenshare
    }

    /// NAL unit packetization arrangement for H264/H265 payloads.
    public enum PacketizationMode: Sendable {
        /// Mode 1, STAP-A and FU-A allowed.
        case nonInterleaved
        /// Mode 0, only single NAL units allowed.
        case singleNalUnit
    }

    /// Codec specific packetization details attached to an encoded frame.
    /// Omit for codecs other than H264/H265.
    public enum CodecSpecificInfo: Sendable {
        case h264(packetizationMode: PacketizationMode)
        case h265(packetizationMode: PacketizationMode)
    }

    /// The encoded bitstream.
    public let data: Data

    /// Resolution of the encoded frame.
    public let dimensions: Dimensions

    /// RTP timestamp in 90kHz clock, typically derived from the source frame's `timeStampNs`.
    public let rtpTimestamp: UInt32

    /// Capture time in milliseconds.
    public let captureTimeMs: Int64

    /// Whether this is a key or delta frame.
    public let frameType: FrameType

    /// Rotation of the source frame.
    public let rotation: VideoRotation

    /// Quantization parameter the frame was encoded with, if known.
    public let qp: Int?

    /// The kind of content carried by the frame.
    public let contentType: ContentType

    /// Codec specific packetization details, required for correct H264/H265 packetization.
    public let codecSpecificInfo: CodecSpecificInfo?

    public init(data: Data,
                dimensions: Dimensions,
                rtpTimestamp: UInt32,
                captureTimeMs: Int64,
                frameType: FrameType,
                rotation: VideoRotation = ._0,
                qp: Int? = nil,
                contentType: ContentType = .unspecified,
                codecSpecificInfo: CodecSpecificInfo? = nil)
    {
        self.data = data
        self.dimensions = dimensions
        self.rtpTimestamp = rtpTimestamp
        self.captureTimeMs = captureTimeMs
        self.frameType = frameType
        self.rotation = rotation
        self.qp = qp
        self.contentType = contentType
        self.codecSpecificInfo = codecSpecificInfo
    }
}

// MARK: - Internal

extension EncodedVideoFrame.FrameType {
    init?(fromRTCType rtcType: LKRTCFrameType) {
        switch rtcType {
        case .emptyFrame: self = .empty
        case .videoFrameKey: self = .key
        case .videoFrameDelta: self = .delta
        default: return nil
        }
    }

    func toRTCType() -> LKRTCFrameType {
        switch self {
        case .empty: .emptyFrame
        case .key: .videoFrameKey
        case .delta: .videoFrameDelta
        }
    }
}

extension EncodedVideoFrame {
    private final class GenericCodecSpecificInfo: NSObject, LKRTCCodecSpecificInfo {}

    func toRTCType() -> (LKRTCEncodedImage, LKRTCCodecSpecificInfo) {
        let image = LKRTCEncodedImage()
        image.buffer = data
        image.encodedWidth = dimensions.width
        image.encodedHeight = dimensions.height
        image.timeStamp = rtpTimestamp
        image.captureTimeMs = captureTimeMs
        image.frameType = frameType.toRTCType()
        image.rotation = rotation.toRTCType()
        image.contentType = contentType == .screenshare ? .screenshare : .unspecified
        if let qp {
            image.qp = NSNumber(value: qp)
        }

        switch codecSpecificInfo {
        case let .h264(packetizationMode):
            let h264Info = LKRTCCodecSpecificInfoH264()
            h264Info.packetizationMode = packetizationMode == .singleNalUnit ? .singleNalUnit : .nonInterleaved
            return (image, h264Info)
        case let .h265(packetizationMode):
            let h265Info = LKRTCCodecSpecificInfoH265()
            h265Info.packetizationMode = packetizationMode == .singleNalUnit ? .singleNalUnit : .nonInterleaved
            return (image, h265Info)
        case nil:
            return (image, GenericCodecSpecificInfo())
        }
    }
}
