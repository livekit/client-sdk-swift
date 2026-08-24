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
    /// Sets a custom ``VideoEncoderFactory`` used to create video encoders,
    /// replacing the SDK's default VideoToolbox backed encoders.
    ///
    /// The factory is wrapped in WebRTC's simulcast encoder adapter, so each
    /// simulcast layer is encoded by an encoder created from this factory.
    ///
    /// Pass `nil` to restore the default factory.
    ///
    /// ```swift
    /// try LiveKitSDK.set(videoEncoderFactory: MyEncoderFactory())
    /// let room = Room()
    /// try await room.connect(url: url, token: token)
    /// ```
    ///
    /// - Warning: Must be called before the first `Room` connection or track
    ///   creation. Throws ``LiveKitError`` with type `.invalidState` afterwards,
    ///   since the underlying peer connection factory is created once per process.
    static func set(videoEncoderFactory: (any VideoEncoderFactory)?) throws {
        try RTC.pcFactoryState.mutate {
            guard !$0.isInitialized else {
                throw LiveKitError(.invalidState, message: "Cannot set videoEncoderFactory after the peer connection factory has been initialized")
            }
            $0.customVideoEncoderFactory = videoEncoderFactory
        }
    }
}
