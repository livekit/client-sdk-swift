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
    /// Pass `exclusive: true` to keep VideoToolbox out of the graph entirely.
    ///
    /// Only H264 and H265 can be supplied by a custom factory. VP8, VP9 and AV1
    /// need layer or dependency information that the bridge cannot carry yet, so
    /// advertising them throws ``LiveKitError`` with type `.invalidParameter`.
    ///
    /// Pass `nil` to restore the default factory.
    ///
    /// ```swift
    /// try LiveKitSDK.set(videoEncoderFactory: MyEncoderFactory())
    /// let room = Room()
    /// try await room.connect(url: url, token: token)
    /// ```
    ///
    /// - Parameter exclusive: Makes this factory the fallback as well, so no video
    ///   is ever encoded by VideoToolbox. Use it when the receiver cannot decode
    ///   anything else. Two consequences: ``VideoEncoderStatus/fallbackSoftware``
    ///   now creates another encoder from this same factory rather than a built in
    ///   one, and every layer creates two encoders from it, one of which stays idle
    ///   unless the fallback triggers.
    ///
    /// - Important: Exclusive publishing still has to negotiate a codec this
    ///   factory advertises. WebRTC's simulcast factory adds VP9 and H265 to the
    ///   advertised list on its own, so a session that negotiates one of those
    ///   finds no encoder at all and the track fails to publish rather than
    ///   falling back. Set ``VideoPublishOptions/preferredCodec`` to a codec the
    ///   factory supports:
    ///
    ///   ```swift
    ///   try LiveKitSDK.set(videoEncoderFactory: MyH264Factory(), exclusive: true)
    ///   let options = VideoPublishOptions(preferredCodec: .h264)
    ///   ```
    ///
    /// - Warning: This method must be called before any other SDK API is used,
    ///   e.g. in the `App.init()` or `application(_:didFinishLaunchingWithOptions:)`.
    ///   Any access to the peer connection factory, such as connecting, creating a
    ///   track, querying capabilities or setting up E2EE, initializes it once per
    ///   process, and this method throws ``LiveKitError`` with type `.invalidState`
    ///   afterwards.
    static func set(videoEncoderFactory: (any VideoEncoderFactory)?, exclusive: Bool = false) throws {
        // Read once and stored alongside the factory, so validation, the advertised
        // list and the codecs the adapter will accept all come from the same snapshot.
        let codecs = (videoEncoderFactory?.supportedCodecs ?? []).map { $0.normalizedForAdvertising() }
        if videoEncoderFactory != nil {
            guard !codecs.isEmpty else {
                throw LiveKitError(.invalidParameter, message: "videoEncoderFactory must advertise at least one supported codec")
            }
            let unsupported = codecs.map(\.name).filter { !Self.bridgeableCodecNames.contains($0.uppercased()) }
            guard unsupported.isEmpty else {
                throw LiveKitError(.invalidParameter, message: "videoEncoderFactory cannot supply encoders for \(unsupported.joined(separator: ", ")), only H264 and H265 are supported")
            }
        }
        try RTC.pcFactoryState.mutate {
            guard !$0.isInitialized, !$0.isEncoderFactoryInitialized else {
                throw LiveKitError(.invalidState, message: "Cannot set videoEncoderFactory after the encoder factory or peer connection factory has been initialized")
            }
            $0.customVideoEncoderFactory = videoEncoderFactory
            $0.customVideoEncoderCodecs = codecs
            $0.customVideoEncoderIsExclusive = videoEncoderFactory != nil && exclusive
        }
    }

    /// Codecs whose RTP packetization needs nothing beyond the H264 packetization
    /// mode the bridge can express. VP8 and VP9 need per frame layer info and AV1
    /// needs a dependency descriptor, none of which reach WebRTC from here.
    private static let bridgeableCodecNames: Set<String> = ["H264", "H265"]
}
