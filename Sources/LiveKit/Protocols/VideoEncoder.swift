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

/// Result of a ``VideoEncoder`` operation, mirroring WebRTC's video codec error codes.
public struct VideoEncoderStatus: RawRepresentable, Sendable, Equatable, Hashable {
    /// The underlying WebRTC video codec error code.
    public let rawValue: Int

    /// Creates a status from a WebRTC video codec error code.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The operation completed successfully.
    public static let ok = Self(rawValue: 0)
    /// The operation failed with a generic error.
    public static let error = Self(rawValue: -1)
    /// The operation failed due to a memory allocation failure.
    public static let memory = Self(rawValue: -3)
    /// The operation failed due to an invalid parameter.
    public static let invalidParameter = Self(rawValue: -4)
    /// The operation timed out.
    public static let timeout = Self(rawValue: -6)
    /// The encoder has not been initialized via ``VideoEncoder/startEncode(with:numberOfCores:)``.
    public static let uninitialized = Self(rawValue: -7)
    /// Requests WebRTC to fall back to another encoder for this codec.
    public static let fallbackSoftware = Self(rawValue: -13)
    /// The encoder produced significantly more bits than the target bitrate.
    public static let targetBitrateOvershoot = Self(rawValue: -14)
    /// The encoder cannot honor the requested simulcast configuration.
    public static let simulcastParametersNotSupported = Self(rawValue: -15)
    /// The encoder failed and should be released.
    public static let encoderFailure = Self(rawValue: -16)
}

extension VideoEncoderStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .ok: "ok"
        case .error: "error"
        case .memory: "memory"
        case .invalidParameter: "invalidParameter"
        case .timeout: "timeout"
        case .uninitialized: "uninitialized"
        case .fallbackSoftware: "fallbackSoftware"
        case .targetBitrateOvershoot: "targetBitrateOvershoot"
        case .simulcastParametersNotSupported: "simulcastParametersNotSupported"
        case .encoderFailure: "encoderFailure"
        default: "unknown(\(rawValue))"
        }
    }
}

/// Delivers an ``EncodedVideoFrame`` produced by a custom ``VideoEncoder`` to WebRTC.
///
/// Returns `true` if the frame was accepted for packetization and transport.
public typealias VideoEncoderCallback = @Sendable (EncodedVideoFrame) -> Bool

/// A custom video encoder implementation, mirroring WebRTC's `VideoEncoder` interface.
///
/// Create instances from a ``VideoEncoderFactory`` registered via
/// ``LiveKitSDK/set(videoEncoderFactory:)``. WebRTC drives the encoder lifecycle:
/// `setCallback` and `startEncode` are called before the first frame, then `encode`
/// per captured frame, with `setBitrate` adapting to network conditions, and
/// finally `releaseEncoder`.
public protocol VideoEncoder: Sendable {
    /// Human readable name of the encoder implementation reported in stats.
    var implementationName: String { get }

    /// Encoded resolutions must be aligned to this value. Defaults to 1.
    var resolutionAlignment: Int { get }

    /// Whether ``resolutionAlignment`` is applied to all simulcast layers simultaneously.
    /// Defaults to `false`.
    var applyAlignmentToAllSimulcastLayers: Bool { get }

    /// Whether the encoder accepts frames backed by `CVPixelBuffer` directly.
    ///
    /// Returning `false` only affects how WebRTC crops and scales frames for
    /// simulcast layers. Frames are still delivered in their native format,
    /// typically NV12, so an encoder needing planar data must call
    /// ``VideoFrame/toI420()`` itself. Defaults to `true`.
    var supportsNativeHandle: Bool { get }

    /// QP thresholds for WebRTC's quality scaler, or `nil` to disable quality scaling.
    /// Defaults to `nil`.
    var scalingSettings: VideoEncoderQpThresholds? { get }

    /// Sets the callback used to deliver encoded frames. Pass `nil` to clear.
    func setCallback(_ callback: VideoEncoderCallback?)

    /// Prepares the encoder for the given settings.
    func startEncode(with settings: VideoEncoderSettings, numberOfCores: Int) -> VideoEncoderStatus

    /// Encodes a single frame. Deliver the result asynchronously via the callback
    /// set in ``setCallback(_:)``. The encoded output must carry the frame's
    /// ``VideoFrame/rtpTimestamp``.
    /// - Parameter frameTypes: Requested frame types, one entry per stream. A `.key`
    ///   entry requests a key frame.
    func encode(_ frame: VideoFrame, frameTypes: [EncodedVideoFrame.FrameType]) -> VideoEncoderStatus

    /// Updates the target bitrate (kilobits per second) and framerate.
    func setBitrate(_ bitrateKbps: UInt32, framerate: UInt32) -> VideoEncoderStatus

    /// Releases encoder resources. No frames may be delivered to the callback
    /// after this returns. The encoder may be started again afterwards.
    func releaseEncoder() -> VideoEncoderStatus
}

public extension VideoEncoder {
    var resolutionAlignment: Int { 1 }
    var applyAlignmentToAllSimulcastLayers: Bool { false }
    var supportsNativeHandle: Bool { true }
    var scalingSettings: VideoEncoderQpThresholds? { nil }
}
