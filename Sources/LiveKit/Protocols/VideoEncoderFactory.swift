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

/// Provides custom video encoders to the SDK, mirroring WebRTC's `VideoEncoderFactory`.
///
/// Register a factory via ``LiveKitSDK/set(videoEncoderFactory:)`` before connecting
/// to a ``Room`` to replace the SDK's default VideoToolbox backed encoders.
///
/// ```swift
/// final class MyEncoderFactory: VideoEncoderFactory {
///     var supportedCodecs: [VideoCodecInfo] { [VideoCodecInfo(name: "VP8")] }
///
///     func createEncoder(for codec: VideoCodecInfo) -> (any VideoEncoder)? {
///         codec.name == "VP8" ? MyVP8Encoder() : nil
///     }
/// }
///
/// try LiveKitSDK.set(videoEncoderFactory: MyEncoderFactory())
/// ```
public protocol VideoEncoderFactory: Sendable {
    /// The codecs this factory can create encoders for. Determines which codecs
    /// are advertised for publishing.
    var supportedCodecs: [VideoCodecInfo] { get }

    /// Creates an encoder for the given codec, or `nil` if the codec is not supported.
    func createEncoder(for codec: VideoCodecInfo) -> (any VideoEncoder)?
}
