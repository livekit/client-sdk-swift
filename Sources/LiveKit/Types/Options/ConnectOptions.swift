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

/// Options used when establishing a connection.
@objcMembers
public final class ConnectOptions: NSObject, Sendable {
    /// Automatically subscribe to ``RemoteParticipant``'s tracks.
    /// Defaults to true.
    public let autoSubscribe: Bool

    /// The number of attempts to reconnect when the network disconnects.
    public let reconnectAttempts: Int

    /// The delay before the second reconnection attempt.
    /// Default is 0.3 seconds (TimeInterval.defaultReconnectDelay).
    ///
    /// Later delays grow from this value. See `reconnectMaxDelay` for how the reconnection delay is calculated.
    public let reconnectAttemptDelay: TimeInterval

    /// The maximum delay between reconnect attempts.
    /// Default is 7 seconds (TimeInterval.defaultReconnectMaxDelay).
    ///
    /// The wait after the n-th failed attempt is `reconnectAttemptDelay` times n squared, capped at `reconnectMaxDelay`,
    /// less a random part of up to 10 percent. A negative delay counts as zero. A wait is never above a
    /// `reconnectMaxDelay` of zero or more.
    ///
    /// Example with the defaults, before the random part: 0.3s, 1.2s, 2.7s, 4.8s, then 7s.
    ///
    /// The first retries follow quickly, so a short outage recovers soon.
    public let reconnectMaxDelay: TimeInterval

    /// The timeout interval for the initial websocket connection.
    /// - Note: It applies to each attempt: a redirect or a Basic authentication retry starts a new timeout.
    public let socketConnectTimeoutInterval: TimeInterval

    public let primaryTransportConnectTimeout: TimeInterval

    public let publisherTransportConnectTimeout: TimeInterval

    /// Custom ice servers
    public let iceServers: [IceServer]

    public let iceTransportPolicy: IceTransportPolicy

    /// Allows DSCP codes to be set on outgoing packets when network priority is used.
    /// Defaults to false.
    public let isDscpEnabled: Bool

    /// Enable microphone concurrently while connecting.
    public let enableMicrophone: Bool

    /// LiveKit server protocol version to use. Generally, it's not recommended to change this.
    public let protocolVersion: ProtocolVersion

    /// Client-to-client protocol version advertised to other participants.
    ///
    /// Defaults to ``ClientProtocol/v2``, which enables data streams v2.
    /// Generally, it's not recommended to change this.
    public let clientProtocol: ClientProtocol

    override public init() {
        autoSubscribe = true
        reconnectAttempts = 10
        reconnectAttemptDelay = .defaultReconnectDelay
        reconnectMaxDelay = .defaultReconnectMaxDelay
        socketConnectTimeoutInterval = .defaultSocketConnect
        primaryTransportConnectTimeout = .defaultTransportState
        publisherTransportConnectTimeout = .defaultTransportState
        iceServers = []
        iceTransportPolicy = .all
        isDscpEnabled = false
        enableMicrophone = false
        protocolVersion = .v16
        clientProtocol = .v2
    }

    public init(autoSubscribe: Bool = true,
                reconnectAttempts: Int = 10,
                reconnectAttemptDelay: TimeInterval = .defaultReconnectDelay,
                reconnectMaxDelay: TimeInterval = .defaultReconnectMaxDelay,
                socketConnectTimeoutInterval: TimeInterval = .defaultSocketConnect,
                primaryTransportConnectTimeout: TimeInterval = .defaultTransportState,
                publisherTransportConnectTimeout: TimeInterval = .defaultTransportState,
                iceServers: [IceServer] = [],
                iceTransportPolicy: IceTransportPolicy = .all,
                isDscpEnabled: Bool = false,
                enableMicrophone: Bool = false,
                protocolVersion: ProtocolVersion = .v16,
                clientProtocol: ClientProtocol = .v2)
    {
        self.autoSubscribe = autoSubscribe
        self.reconnectAttempts = reconnectAttempts
        self.reconnectAttemptDelay = reconnectAttemptDelay
        self.reconnectMaxDelay = max(reconnectMaxDelay, reconnectAttemptDelay)
        self.socketConnectTimeoutInterval = socketConnectTimeoutInterval
        self.primaryTransportConnectTimeout = primaryTransportConnectTimeout
        self.publisherTransportConnectTimeout = publisherTransportConnectTimeout
        self.iceServers = iceServers
        self.iceTransportPolicy = iceTransportPolicy
        self.isDscpEnabled = isDscpEnabled
        self.enableMicrophone = enableMicrophone
        self.protocolVersion = protocolVersion
        self.clientProtocol = clientProtocol
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return autoSubscribe == other.autoSubscribe &&
            reconnectAttempts == other.reconnectAttempts &&
            reconnectAttemptDelay == other.reconnectAttemptDelay &&
            reconnectMaxDelay == other.reconnectMaxDelay &&
            socketConnectTimeoutInterval == other.socketConnectTimeoutInterval &&
            primaryTransportConnectTimeout == other.primaryTransportConnectTimeout &&
            publisherTransportConnectTimeout == other.publisherTransportConnectTimeout &&
            iceServers == other.iceServers &&
            iceTransportPolicy == other.iceTransportPolicy &&
            isDscpEnabled == other.isDscpEnabled &&
            enableMicrophone == other.enableMicrophone &&
            protocolVersion == other.protocolVersion &&
            clientProtocol == other.clientProtocol
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(autoSubscribe)
        hasher.combine(reconnectAttempts)
        hasher.combine(reconnectAttemptDelay)
        hasher.combine(reconnectMaxDelay)
        hasher.combine(socketConnectTimeoutInterval)
        hasher.combine(primaryTransportConnectTimeout)
        hasher.combine(publisherTransportConnectTimeout)
        hasher.combine(iceServers)
        hasher.combine(iceTransportPolicy)
        hasher.combine(isDscpEnabled)
        hasher.combine(enableMicrophone)
        hasher.combine(protocolVersion)
        return hasher.finalize()
    }
}
