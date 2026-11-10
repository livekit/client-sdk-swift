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

/// Provides custom video decoders to the SDK, mirroring WebRTC's `VideoDecoderFactory`.
///
/// Register via ``LiveKitSDK/set(videoDecoderFactory:)`` before using other SDK APIs.
/// The factory selects by codec only. It cannot target a single track because
/// WebRTC does not pass receiver identity to decoder factories.
public protocol VideoDecoderFactory: Sendable {
    /// The codecs this factory advertises in addition to the SDK's built in codecs.
    /// The built in codecs remain advertised even when this list is empty.
    var supportedCodecs: [VideoCodecInfo] { get }

    /// Creates a decoder for the given codec, or returns `nil` to keep the built in decoder.
    ///
    /// WebRTC currently selects an advertised format by codec name, so its
    /// parameters are not guaranteed to describe the negotiated profile.
    /// This method can be called for built in codecs as well as ``supportedCodecs``.
    func createDecoder(for codec: VideoCodecInfo) -> (any VideoDecoder)?
}
