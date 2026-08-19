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

// This file intentionally exposes `LiveKitWebRTC` publicly: providing a custom video
// encoder factory necessarily means accepting an `LKRTCVideoEncoderFactory` from the caller.
// It is the only public surface that leaks the WebRTC module.
public import LiveKitWebRTC

public extension LiveKitSDK {
    /// Sets a custom video encoder factory to be used by the underlying WebRTC
    /// `PeerConnectionFactory`, replacing the default VideoToolbox-backed factory.
    ///
    /// Pass `nil` to restore the default factory.
    ///
    /// This must be called **before** the peer connection factory is initialized (i.e. before
    /// the first `Room` connection / track creation). Calling it afterwards throws, because the
    /// factory is created once and cached for the lifetime of the process.
    static func set(videoEncoderFactory: (LKRTCVideoEncoderFactory & Sendable)?) throws {
        guard !RTC.pcFactoryState.isInitialized else {
            throw LiveKitError(.invalidState, message: "Cannot set videoEncoderFactory after the peer connection has been initialized")
        }
        RTC.pcFactoryState.mutate { $0.customVideoEncoderFactory = videoEncoderFactory }
    }
}
