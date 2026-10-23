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

/// Configuration passed to ``VideoEncoder/startEncode(with:numberOfCores:)``.
public struct VideoEncoderSettings: Sendable {
    /// The kind of content being encoded, which encoders may use to tune rate control.
    public enum Mode: Sendable {
        /// Live camera or application video, where latency matters most.
        case realtimeVideo
        /// Screen content, which is often static and benefits from higher quality.
        case screensharing
    }

    /// The codec name this encoder was created for, e.g. `H264`.
    public let name: String

    /// Resolution of the stream to encode.
    public let dimensions: Dimensions

    /// Initial target bitrate in kilobits per second.
    public let startBitrateKbps: UInt32

    /// Maximum bitrate in kilobits per second.
    public let maxBitrateKbps: UInt32

    /// Minimum bitrate in kilobits per second.
    public let minBitrateKbps: UInt32

    /// Maximum framerate in frames per second.
    public let maxFramerate: UInt32

    /// Maximum allowed quantization parameter.
    public let qpMax: UInt32

    /// The kind of content being encoded.
    public let mode: Mode

    /// Creates encoder settings, which is useful for testing an encoder without
    /// a live connection.
    public init(name: String,
                dimensions: Dimensions,
                startBitrateKbps: UInt32,
                maxBitrateKbps: UInt32,
                minBitrateKbps: UInt32,
                maxFramerate: UInt32,
                qpMax: UInt32,
                mode: Mode)
    {
        self.name = name
        self.dimensions = dimensions
        self.startBitrateKbps = startBitrateKbps
        self.maxBitrateKbps = maxBitrateKbps
        self.minBitrateKbps = minBitrateKbps
        self.maxFramerate = maxFramerate
        self.qpMax = qpMax
        self.mode = mode
    }
}

/// QP thresholds controlling WebRTC's quality scaler, see ``VideoEncoder/scalingSettings``.
public struct VideoEncoderQpThresholds: Sendable {
    /// Below this QP the resolution may be increased.
    public let low: Int

    /// Above this QP the resolution may be decreased.
    public let high: Int

    /// Creates QP thresholds for the quality scaler.
    public init(low: Int, high: Int) {
        self.low = low
        self.high = high
    }
}

// MARK: - Internal

extension VideoEncoderSettings {
    init(fromRTCType rtcType: LKRTCVideoEncoderSettings) {
        name = rtcType.name
        dimensions = Dimensions(width: Int32(rtcType.width), height: Int32(rtcType.height))
        startBitrateKbps = rtcType.startBitrate
        maxBitrateKbps = rtcType.maxBitrate
        minBitrateKbps = rtcType.minBitrate
        maxFramerate = rtcType.maxFramerate
        qpMax = rtcType.qpMax
        mode = rtcType.mode == .screensharing ? .screensharing : .realtimeVideo
    }
}

extension VideoEncoderQpThresholds {
    func toRTCType() -> LKRTCVideoEncoderQpThresholds {
        LKRTCVideoEncoderQpThresholds(thresholdsLow: low, high: high)
    }
}
