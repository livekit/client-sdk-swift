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
    /// Sets a custom ``VideoEncoderFactory`` used to create video encoders for
    /// the codecs it supports, taking over from the SDK's default VideoToolbox
    /// backed encoders for those codecs.
    ///
    /// The factory is wrapped in WebRTC's simulcast encoder adapter, so each
    /// simulcast layer is encoded by an encoder created from this factory. The
    /// SDK's built in encoders remain the fallback, both for codecs the factory
    /// declines and when an encoder reports ``VideoEncoderStatus/fallbackSoftware``.
    ///
    /// Only H264, H265 and AV1 can be supplied by a custom factory. VP8 and VP9
    /// require codec specific layer information that the bridge cannot carry
    /// yet, so advertising them throws ``LiveKitError`` with type `.invalidParameter`.
    ///
    /// Pass `nil` to restore the default factory.
    ///
    /// ```swift
    /// try LiveKitSDK.set(videoEncoderFactory: MyEncoderFactory())
    /// let room = Room()
    /// try await room.connect(url: url, token: token)
    /// ```
    ///
    /// - Warning: This method must be called before any other SDK API is used,
    ///   e.g. in the `App.init()` or `application(_:didFinishLaunchingWithOptions:)`.
    ///   Any access to the peer connection factory, such as connecting, creating a
    ///   track, querying capabilities or setting up E2EE, initializes it once per
    ///   process, and this method throws ``LiveKitError`` with type `.invalidState`
    ///   afterwards.
    static func set(videoEncoderFactory: (any VideoEncoderFactory)?) throws {
        if let videoEncoderFactory {
            let codecs = videoEncoderFactory.supportedCodecs
            guard !codecs.isEmpty else {
                throw LiveKitError(.invalidParameter, message: "videoEncoderFactory must advertise at least one supported codec")
            }
            let unsupported = codecs.map(\.name).filter { !Self.bridgeableCodecNames.contains($0.uppercased()) }
            guard unsupported.isEmpty else {
                throw LiveKitError(.invalidParameter, message: "videoEncoderFactory cannot supply encoders for \(unsupported.joined(separator: ", ")), only H264, H265 and AV1 are supported")
            }
        }
        try RTC.pcFactoryState.mutate {
            guard !$0.isInitialized else {
                throw LiveKitError(.invalidState, message: "Cannot set videoEncoderFactory after the peer connection factory has been initialized")
            }
            $0.customVideoEncoderFactory = videoEncoderFactory
        }
    }

    /// Codecs whose RTP packetization needs no codec specific info beyond what
    /// ``EncodedVideoFrame/CodecSpecificInfo`` can express.
    private static let bridgeableCodecNames: Set<String> = ["H264", "H265", "AV1"]
}
