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

public extension LiveKitSDK {
    /// Sets a custom ``VideoDecoderFactory`` used to create video decoders.
    ///
    /// The SDK asks the custom factory first and uses the built in decoder when
    /// it returns `nil`. Built in codecs remain advertised. Pass `nil` to restore
    /// the default factory. Fallback occurs at creation, not after a decode error.
    ///
    /// ```swift
    /// try LiveKitSDK.set(videoDecoderFactory: MyDecoderFactory())
    /// let room = Room()
    /// try await room.connect(url: url, token: token)
    /// ```
    ///
    /// - Note: Selection is by codec, not by track. Per-track selection needs
    ///   receiver identity that WebRTC does not pass to decoder factories today.
    /// - Warning: Call this before any other SDK API, for example in `App.init()`.
    ///   Accessing the decoder factory or shared peer connection factory fixes
    ///   the configuration for the process. Later calls throw ``LiveKitError``
    ///   with type `.invalidState`.
    static func set(videoDecoderFactory: (any VideoDecoderFactory)?) throws {
        let codecs = (videoDecoderFactory?.supportedCodecs ?? []).map { $0.normalizedForAdvertising() }
        try RTC.pcFactoryState.mutate {
            guard !$0.isInitialized, !$0.isDecoderFactoryInitialized else {
                throw LiveKitError(.invalidState, message: "Cannot set videoDecoderFactory after the decoder factory or peer connection factory has been initialized")
            }
            $0.customVideoDecoderFactory = videoDecoderFactory
            $0.customVideoDecoderCodecs = codecs
        }
    }
}
