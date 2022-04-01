/*
 * Copyright 2022 LiveKit
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
import WebRTC

/// Options used when establishing a connection.
public struct ConnectOptions {

    /// Automatically subscribe to ``RemoteParticipant``'s tracks.
    /// Defaults to true.
    public let autoSubscribe: Bool
    public let rtcConfiguration: RTCConfiguration
    /// LiveKit server protocol version to use. Generally, it's not recommended to change this.
    public let protocolVersion: ProtocolVersion
    /// Providing a string will make the connection publish-only, suitable for iOS Broadcast Upload Extensions.
    /// The string can be used to identify the publisher.
    public let publishOnlyMode: String?

    public init(autoSubscribe: Bool = true,
                rtcConfiguration: RTCConfiguration = .liveKitDefault(),
                publishOnlyMode: String? = nil,
                protocolVersion: ProtocolVersion = .v7) {

        self.autoSubscribe = autoSubscribe
        self.rtcConfiguration = rtcConfiguration
        self.publishOnlyMode = publishOnlyMode
        self.protocolVersion = protocolVersion
    }
}
