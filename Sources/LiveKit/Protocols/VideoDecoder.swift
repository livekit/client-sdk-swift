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

/// Result of a ``VideoDecoder`` operation, mirroring WebRTC's video codec error codes.
public struct VideoDecoderStatus: RawRepresentable, Sendable, Equatable, Hashable {
    /// The underlying WebRTC video codec error code.
    public let rawValue: Int

    /// Creates a status from a WebRTC video codec error code.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The operation completed successfully.
    public static let ok = Self(rawValue: 0)
    /// No decoded frame will be delivered for this input.
    public static let noOutput = Self(rawValue: 1)
    /// The frame was decoded, but the decoder requests a new key frame.
    public static let okRequestKeyframe = Self(rawValue: 4)
    /// The operation failed with a generic error.
    public static let error = Self(rawValue: -1)
    /// The operation failed due to a memory allocation failure.
    public static let memory = Self(rawValue: -3)
    /// The operation failed due to an invalid parameter.
    public static let invalidParameter = Self(rawValue: -4)
    /// The operation timed out.
    public static let timeout = Self(rawValue: -6)
    /// The decoder has not been initialized via ``VideoDecoder/startDecode(numberOfCores:)``.
    public static let uninitialized = Self(rawValue: -7)
}

extension VideoDecoderStatus: CustomStringConvertible {
    /// A readable name for the status, including the raw value for unknown codes.
    public var description: String {
        switch self {
        case .ok: "ok"
        case .noOutput: "noOutput"
        case .okRequestKeyframe: "okRequestKeyframe"
        case .error: "error"
        case .memory: "memory"
        case .invalidParameter: "invalidParameter"
        case .timeout: "timeout"
        case .uninitialized: "uninitialized"
        default: "unknown(\(rawValue))"
        }
    }
}

/// Delivers a decoded ``VideoFrame`` to WebRTC from any thread.
/// The frame must carry the input ``EncodedVideoFrame/rtpTimestamp``.
public typealias VideoDecoderCallback = @Sendable (VideoFrame) -> Void

/// A custom video decoder implementation, mirroring WebRTC's `VideoDecoder` interface.
///
/// Create instances from a ``VideoDecoderFactory`` registered via
/// ``LiveKitSDK/set(videoDecoderFactory:)``. WebRTC calls `startDecode` and
/// `setCallback` before decoding frames, then calls `releaseDecoder` at teardown.
/// The callback must not be required until the first `decode`.
///
/// ### Threading
///
/// WebRTC sequences lifecycle calls and ``decode(_:missingFrames:renderTimeMs:)``
/// on its decode queue, which is separate from Swift Concurrency's executors.
/// Calls can arrive on different threads. Do not block this queue for long.
/// Submit expensive work to your decoder and deliver output through the callback,
/// which may be called from any thread. Keep ``implementationName`` safe to read
/// from any thread. Do not hold a lock across the callback that lifecycle calls also take.
public protocol VideoDecoder: Sendable {
    /// Human readable name of the decoder implementation reported in stats.
    var implementationName: String { get }

    /// Sets the callback used to deliver decoded frames. Pass `nil` to clear.
    func setCallback(_ callback: VideoDecoderCallback?)

    /// Prepares the decoder with the number of CPU cores available to WebRTC.
    func startDecode(numberOfCores: Int) -> VideoDecoderStatus

    /// Decodes a frame and delivers its output through the callback.
    ///
    /// The SDK copies the encoded bytes, so `frame.data` can be retained after
    /// this method returns. Return `.ok` when output will arrive asynchronously,
    /// and `.noOutput` only when this input will produce no callback.
    /// The output must copy ``EncodedVideoFrame/rtpTimestamp``
    /// into ``VideoFrame/rtpTimestamp``. WebRTC uses it to match output to input
    /// and drops frames without a match. Use ``CVPixelVideoBuffer`` or
    /// ``I420VideoBuffer`` for output. Other buffer types are dropped.
    /// - Parameters:
    ///   - missingFrames: Whether preceding frames were lost. The current bridge always passes `false`.
    ///   - renderTimeMs: WebRTC's requested render time in milliseconds, or `-1` when unspecified.
    func decode(_ frame: EncodedVideoFrame, missingFrames: Bool, renderTimeMs: Int64) -> VideoDecoderStatus

    /// Releases decoder resources. No callbacks can remain in flight or be
    /// delivered after this returns. Cancel pending asynchronous output and drain
    /// in-flight deliveries before returning, without holding a lock those deliveries need.
    func releaseDecoder() -> VideoDecoderStatus
}
