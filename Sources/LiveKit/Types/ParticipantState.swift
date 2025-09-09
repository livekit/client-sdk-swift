/*
 * Copyright 2025 LiveKit
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

/// Describes the state of a ``Participant``'s connection to the LiveKit server.
@objc
public enum ParticipantState: Int, Sendable, CaseIterable {
    /// Websocket is connected, but no offer has been sent yet
    case joining = 0

    /// Server has received the client's offer
    case joined = 1

    /// ICE connectivity has been established
    case active = 2

    /// Websocket has disconnected
    case disconnected = 3

    /// Unknown state
    case unknown = 999
}

// MARK: - Conversions from/to protobuf types

extension ParticipantState {
    init(from protoState: Livekit_ParticipantInfo.State) {
        switch protoState {
        case .joining:
            self = .joining
        case .joined:
            self = .joined
        case .active:
            self = .active
        case .disconnected:
            self = .disconnected
        case .UNRECOGNIZED:
            self = .unknown
        }
    }

    var protoState: Livekit_ParticipantInfo.State {
        switch self {
        case .joining:
            .joining
        case .joined:
            .joined
        case .active:
            .active
        case .disconnected:
            .disconnected
        case .unknown:
            .joining // Default to joining for unknown state
        }
    }
}

extension Livekit_ParticipantInfo.State {
    func toLKType() -> ParticipantState {
        ParticipantState(from: self)
    }
}

extension ParticipantState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .joining:
            "joining"
        case .joined:
            "joined"
        case .active:
            "active"
        case .disconnected:
            "disconnected"
        case .unknown:
            "unknown"
        }
    }
}
