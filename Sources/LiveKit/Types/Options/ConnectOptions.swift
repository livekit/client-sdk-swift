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

    public static func == (lhs: ConnectOptions, rhs: ConnectOptions) -> Bool {
        lhs.autoSubscribe == rhs.autoSubscribe &&
            lhs.rtcConfiguration == rhs.rtcConfiguration &&
            lhs.protocolVersion == rhs.protocolVersion  &&
            lhs.publishOnlyMode == rhs.publishOnlyMode
    }

    /// Automatically subscribe to ``RemoteParticipant``'s tracks.
    /// Defaults to true.
    @objc
    public let autoSubscribe: Bool
    @objc
    public let rtcConfiguration: RTCConfiguration
    /// LiveKit server protocol version to use. Generally, it's not recommended to change this.
    @objc
    public let protocolVersion: ProtocolVersion
    /// Providing a string will make the connection publish-only, suitable for iOS Broadcast Upload Extensions.
    /// The string can be used to identify the publisher.
    @objc
    public let publishOnlyMode: String?

    @objc
    public override init() {
        self.autoSubscribe = true
        self.rtcConfiguration = .liveKitDefault()
        self.publishOnlyMode = nil
        self.protocolVersion = .v8
    }

    @objc
    public init(autoSubscribe: Bool = true,
                rtcConfiguration: RTCConfiguration? = nil,
                publishOnlyMode: String? = nil,
                protocolVersion: ProtocolVersion = .v8) {

        self.autoSubscribe = autoSubscribe
        self.rtcConfiguration = rtcConfiguration ?? .liveKitDefault()
        self.publishOnlyMode = publishOnlyMode
        self.protocolVersion = protocolVersion
    }
}

public extension ConnectOptions {

    func copyWith(autoSubscribe: Bool? = nil,
                  rtcConfiguration: RTCConfiguration? = nil,
                  protocolVersion: ProtocolVersion? = nil) -> ConnectOptions {

        ConnectOptions(autoSubscribe: autoSubscribe ?? self.autoSubscribe,
                       rtcConfiguration: rtcConfiguration ?? self.rtcConfiguration,
                       protocolVersion: protocolVersion ?? self.protocolVersion)
    }
}
