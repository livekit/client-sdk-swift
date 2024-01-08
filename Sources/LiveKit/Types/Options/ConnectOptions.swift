/*
 * Copyright 2024 LiveKit
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

/// Options used when establishing a connection.
@objc
public class ConnectOptions: NSObject {
    /// Automatically subscribe to ``RemoteParticipant``'s tracks.
    /// Defaults to true.
    @objc
    public let autoSubscribe: Bool

    /// Providing a string will make the connection publish-only, suitable for iOS Broadcast Upload Extensions.
    /// The string can be used to identify the publisher.
    @objc
    public let publishOnlyMode: String?

    /// The number of attempts to reconnect when the network disconnects.
    @objc
    public let reconnectAttempts: Int

    /// The delay between reconnect attempts.
    @objc
    public let reconnectAttemptDelay: TimeInterval

    /// Custom ice servers
    @objc
    public let iceServers: [IceServer]

    /// LiveKit server protocol version to use. Generally, it's not recommended to change this.
    @objc
    public let protocolVersion: ProtocolVersion

    @objc
    override public init() {
        autoSubscribe = true
        publishOnlyMode = nil
        reconnectAttempts = 3
        reconnectAttemptDelay = .defaultReconnectAttemptDelay
        iceServers = []
        protocolVersion = .v12
    }

    @objc
    public init(autoSubscribe: Bool = true,
                publishOnlyMode: String? = nil,
                reconnectAttempts: Int = 3,
                reconnectAttemptDelay: TimeInterval = .defaultReconnectAttemptDelay,
                iceServers: [IceServer] = [],
                protocolVersion: ProtocolVersion = .v12)
    {
        self.autoSubscribe = autoSubscribe
        self.publishOnlyMode = publishOnlyMode
        self.reconnectAttempts = reconnectAttempts
        self.reconnectAttemptDelay = reconnectAttemptDelay
        self.iceServers = iceServers
        self.protocolVersion = protocolVersion
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return autoSubscribe == other.autoSubscribe &&
            publishOnlyMode == other.publishOnlyMode &&
            reconnectAttempts == other.reconnectAttempts &&
            reconnectAttemptDelay == other.reconnectAttemptDelay &&
            iceServers == other.iceServers &&
            protocolVersion == other.protocolVersion
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(autoSubscribe)
        hasher.combine(publishOnlyMode)
        hasher.combine(reconnectAttempts)
        hasher.combine(reconnectAttemptDelay)
        hasher.combine(iceServers)
        hasher.combine(protocolVersion)
        return hasher.finalize()
    }
}
