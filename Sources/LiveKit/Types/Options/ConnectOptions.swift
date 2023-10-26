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
@objc
public class ConnectOptions: NSObject {

    /// Automatically subscribe to ``RemoteParticipant``'s tracks.
    /// Defaults to true.
    @objc
    public let autoSubscribe: Bool

    @objc
    public let rtcConfiguration: RTCConfiguration

    /// Providing a string will make the connection publish-only, suitable for iOS Broadcast Upload Extensions.
    /// The string can be used to identify the publisher.
    @objc
    public let publishOnlyMode: String?

    /// LiveKit server protocol version to use. Generally, it's not recommended to change this.
    @objc
    public let protocolVersion: ProtocolVersion

    /// The number of attempts to reconnect when the network disconnects.
    @objc
    public let reconnectAttempts: Int

    /// The delay between reconnect attempts.
    @objc
    public let reconnectAttemptDelay: TimeInterval

    @objc
    public override init() {
        self.autoSubscribe = true
        self.rtcConfiguration = .liveKitDefault()
        self.publishOnlyMode = nil
        self.reconnectAttempts = 3
        self.reconnectAttemptDelay = .defaultReconnectAttemptDelay
        self.protocolVersion = .v9
    }

    @objc
    public init(autoSubscribe: Bool = true,
                rtcConfiguration: RTCConfiguration? = nil,
                publishOnlyMode: String? = nil,
                reconnectAttempts: Int = 3,
                reconnectAttemptDelay: TimeInterval = .defaultReconnectAttemptDelay,
                protocolVersion: ProtocolVersion = .v9) {

        self.autoSubscribe = autoSubscribe
        self.rtcConfiguration = rtcConfiguration ?? .liveKitDefault()
        self.publishOnlyMode = publishOnlyMode
        self.reconnectAttempts = reconnectAttempts
        self.reconnectAttemptDelay = reconnectAttemptDelay
        self.protocolVersion = protocolVersion
    }

    // MARK: - Equal

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return self.autoSubscribe == other.autoSubscribe &&
            self.rtcConfiguration == other.rtcConfiguration &&
            self.publishOnlyMode == other.publishOnlyMode &&
            self.reconnectAttempts == other.reconnectAttempts &&
            self.reconnectAttemptDelay == other.reconnectAttemptDelay &&
            self.protocolVersion == other.protocolVersion
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(autoSubscribe)
        hasher.combine(rtcConfiguration)
        hasher.combine(publishOnlyMode)
        hasher.combine(reconnectAttempts)
        hasher.combine(reconnectAttemptDelay)
        hasher.combine(protocolVersion)
        return hasher.finalize()
    }
}
