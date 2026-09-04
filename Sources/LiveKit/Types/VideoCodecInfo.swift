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

/// Identifies a video codec together with its SDP format parameters.
///
/// Corresponds to WebRTC's `SdpVideoFormat`. A custom ``VideoEncoderFactory`` receives
/// a `VideoCodecInfo` describing which codec an encoder should be created for, and
/// advertises the codecs it supports as a list of `VideoCodecInfo`.
public struct VideoCodecInfo: Hashable, Sendable {
    /// The codec name as used in SDP, e.g. `H264`, `VP8`, `VP9`, `AV1`.
    ///
    /// SDP casing is used, so this is `H264` rather than `h264`. Compare against
    /// ``videoCodec`` instead of matching the string.
    public let name: String

    /// SDP format parameters, e.g. the H264 `profile-level-id`.
    public let parameters: [String: String]

    /// Supported scalability modes, e.g. `L1T3`.
    public let scalabilityModes: [String]

    /// The codec ``name`` resolved to a ``VideoCodec``, or `nil` if the SDK does
    /// not know the codec.
    public var videoCodec: VideoCodec? { VideoCodec.from(name: name) }

    /// Creates a codec description for a custom ``VideoEncoderFactory``.
    public init(name: String,
                parameters: [String: String] = [:],
                scalabilityModes: [String] = [])
    {
        self.name = name
        self.parameters = parameters
        self.scalabilityModes = scalabilityModes
    }
}

// MARK: - Internal

extension VideoCodecInfo {
    init(fromRTCType rtcType: LKRTCVideoCodecInfo) {
        self.init(name: rtcType.name,
                  parameters: rtcType.parameters,
                  scalabilityModes: rtcType.scalabilityModes)
    }

    func toRTCType() -> LKRTCVideoCodecInfo {
        LKRTCVideoCodecInfo(name: name,
                            parameters: parameters,
                            scalabilityModes: scalabilityModes)
    }
}
