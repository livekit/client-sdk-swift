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
///     var supportedCodecs: [VideoCodecInfo] { [VideoCodecInfo(name: "H264")] }
///
///     func createEncoder(for codec: VideoCodecInfo) -> (any VideoEncoder)? {
///         codec.name == "H264" ? MyH264Encoder() : nil
///     }
/// }
///
/// try LiveKitSDK.set(videoEncoderFactory: MyEncoderFactory())
/// ```
public protocol VideoEncoderFactory: Sendable {
    /// The codecs this factory takes over from the SDK's built in encoders. The
    /// built in encoders continue to serve every other codec, so this list can
    /// only add to what is advertised for publishing, never narrow it.
    ///
    /// H264 entries without a `packetization-mode` parameter are advertised as
    /// mode 1, matching how frames are packetized by default. Include the
    /// `profile-level-id` parameter to advertise a specific profile, otherwise
    /// the remote side assumes constrained baseline level 1.
    var supportedCodecs: [VideoCodecInfo] { get }

    /// Creates an encoder for the given codec, or `nil` if the codec is not supported.
    func createEncoder(for codec: VideoCodecInfo) -> (any VideoEncoder)?
}
