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
///
/// Only fields WebRTC actually reads from the encoder are exposed. Capture time,
/// rotation, content type, NTP time and encode timing are filled in by WebRTC
/// from its own record of the source frame, matched by ``rtpTimestamp``.
public struct EncodedVideoFrame: Sendable {
    /// The role of a frame within the encoded stream.
    public enum FrameType: Sendable {
        /// A frame carrying no payload, used to signal a dropped frame.
        case empty
        /// A frame that can be decoded on its own.
        case key
        /// A frame that depends on previously decoded frames.
        case delta
    }

    /// NAL unit packetization arrangement for H264 payloads.
    public enum PacketizationMode: Sendable {
        /// Mode 1, STAP-A and FU-A allowed.
        case nonInterleaved
        /// Mode 0, only single NAL units allowed.
        case singleNalUnit
    }

    /// The encoded bitstream.
    public let data: Data

    /// Resolution of the encoded frame.
    public let dimensions: Dimensions

    /// RTP timestamp in the 90kHz clock, which must be copied from the source
    /// ``VideoFrame/rtpTimestamp`` and not derived from `timeStampNs`.
    public let rtpTimestamp: UInt32

    /// Whether this is a key or delta frame.
    public let frameType: FrameType

    /// Quantization parameter the frame was encoded with, if known.
    public let qp: Int?

    /// How the H264 bitstream is arranged for RTP packetization.
    ///
    /// When `nil`, the mode negotiated for the codec is used, which is
    /// ``PacketizationMode/nonInterleaved`` unless the codec's
    /// `packetization-mode` parameter is `0`. Ignored for H265, whose packetizer
    /// takes no mode.
    public let packetizationMode: PacketizationMode?

    /// Creates an encoded frame to deliver to the SDK.
    public init(data: Data,
                dimensions: Dimensions,
                rtpTimestamp: UInt32,
                frameType: FrameType,
                qp: Int? = nil,
                packetizationMode: PacketizationMode? = nil)
    {
        self.data = data
        self.dimensions = dimensions
        self.rtpTimestamp = rtpTimestamp
        self.frameType = frameType
        self.qp = qp
        self.packetizationMode = packetizationMode
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

extension EncodedVideoFrame.PacketizationMode {
    func toRTCType() -> LKRTCH264PacketizationMode {
        switch self {
        case .nonInterleaved: .nonInterleaved
        case .singleNalUnit: .singleNalUnit
        }
    }
}

extension EncodedVideoFrame {
    private final class GenericCodecSpecificInfo: NSObject, LKRTCCodecSpecificInfo, @unchecked Sendable {}

    // Stateless, so one instance is shared instead of allocating one per frame.
    private static let genericCodecSpecificInfo = GenericCodecSpecificInfo()

    /// - Parameter codec: The codec the encoder was created for. The RTP
    ///   packetizer for H264 requires a matching typed header and aborts on a
    ///   generic or mismatched one, so the codec specific info is always derived
    ///   from this codec, using the frame's packetization mode when given and
    ///   the negotiated mode otherwise.
    func toRTCType(codec: VideoCodecInfo) -> (LKRTCEncodedImage, LKRTCCodecSpecificInfo) {
        let image = LKRTCEncodedImage()
        image.buffer = data
        image.encodedWidth = dimensions.width
        image.encodedHeight = dimensions.height
        image.timeStamp = rtpTimestamp
        image.frameType = frameType.toRTCType()
        // Always set: the native side reads `intValue`, so a nil would land as 0,
        // while -1 is what the quality scaler treats as unknown.
        image.qp = NSNumber(value: qp ?? -1)

        let mode = (packetizationMode ?? codec.negotiatedPacketizationMode).toRTCType()

        switch codec.name.uppercased() {
        case "H264":
            let h264Info = LKRTCCodecSpecificInfoH264()
            h264Info.packetizationMode = mode
            return (image, h264Info)
        case "H265":
            // Separate ObjC enum with the same cases. The H265 packetizer ignores it.
            let h265Info = LKRTCCodecSpecificInfoH265()
            h265Info.packetizationMode = mode == .singleNalUnit ? .singleNalUnit : .nonInterleaved
            return (image, h265Info)
        default:
            return (image, Self.genericCodecSpecificInfo)
        }
    }
}
