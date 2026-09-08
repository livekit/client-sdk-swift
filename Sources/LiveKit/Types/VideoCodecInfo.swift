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
    /// The codec name as used in SDP, e.g. `H264` or `H265`.
    ///
    /// SDP casing is used, so this is `H264` rather than `h264`. Compare against
    /// ``videoCodec`` instead of matching the string.
    public let name: String

    /// SDP format parameters, e.g. the H264 `profile-level-id`.
    public let parameters: [String: String]

    /// The codec ``name`` resolved to a ``VideoCodec``, or `nil` if the SDK does
    /// not know the codec.
    public var videoCodec: VideoCodec? { VideoCodec.from(name: name) }

    /// Creates a codec description for a custom ``VideoEncoderFactory``.
    public init(name: String,
                parameters: [String: String] = [:])
    {
        self.name = name
        self.parameters = parameters
    }
}

// MARK: - Internal

extension VideoCodecInfo {
    static let packetizationModeParameter = "packetization-mode"

    /// The H264 packetization mode negotiated through the SDP
    /// `packetization-mode` parameter. Absent means mode 0 per RFC 6184, but
    /// ``normalizedForAdvertising()`` fills the parameter in before anything is
    /// advertised, so for a negotiated codec it is always present.
    var negotiatedPacketizationMode: EncodedVideoFrame.PacketizationMode {
        parameters[Self.packetizationModeParameter] == "0" ? .singleNalUnit : .nonInterleaved
    }

    /// Makes what is advertised match what the bridge packetizes.
    ///
    /// An H264 format without `packetization-mode` negotiates as mode 0, but
    /// frames without an explicit mode are packetized non interleaved, so the
    /// parameter is set to `1` when absent. This also matches the built in
    /// factory, which only ever advertises mode 1. Single NAL unit mode is
    /// still available by advertising `packetization-mode` `0` explicitly.
    func normalizedForAdvertising() -> VideoCodecInfo {
        guard name.uppercased() == "H264", parameters[Self.packetizationModeParameter] == nil else { return self }
        var parameters = parameters
        parameters[Self.packetizationModeParameter] = "1"
        return VideoCodecInfo(name: name, parameters: parameters)
    }

    init(fromRTCType rtcType: LKRTCVideoCodecInfo) {
        self.init(name: rtcType.name,
                  parameters: rtcType.parameters)
    }

    // Scalability modes are not advertised: without a codec support query on the
    // factory, WebRTC reports every mode as unsupported anyway.
    func toRTCType() -> LKRTCVideoCodecInfo {
        LKRTCVideoCodecInfo(name: name,
                            parameters: parameters,
                            scalabilityModes: [])
    }
}
