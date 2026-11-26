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
    /// Enables sending FlexFEC forward error correction for published video.
    ///
    /// When enabled, published video tracks without simulcast offer `flexfec-03` and can send
    /// repair packets to the server, see ``VideoPublishOptions/fecProtection``.
    /// Disabled by default.
    ///
    /// Receiving needs no switch: WebRTC always accepts `flexfec-03` on subscribed video tracks,
    /// see ``RemoteTrackPublication/set(fecProtection:)``.
    ///
    /// ```swift
    /// try LiveKitSDK.setFlexFECEnabled(true)
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
    static func setFlexFECEnabled(_ enabled: Bool) throws {
        try RTC.pcFactoryState.mutate {
            guard !$0.isInitialized else {
                throw LiveKitError(.invalidState, message: "Cannot change FlexFEC after the peer connection factory has been initialized")
            }
            $0.isFlexFECEnabled = enabled
        }
    }
}
