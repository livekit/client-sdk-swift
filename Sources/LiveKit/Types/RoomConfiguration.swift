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

public struct RoomConfiguration: Encodable, Sendable, Equatable {
    /// Room name, used as ID, must be unique
    public let name: String?

    /// Number of seconds to keep the room open if no one joins
    public let emptyTimeout: UInt32?

    /// Number of seconds to keep the room open after everyone leaves
    public let departureTimeout: UInt32?

    /// Limit number of participants that can be in a room, excluding Egress and Ingress participants
    public let maxParticipants: UInt32?

    /// Metadata of room
    public let metadata: String?

    // Egress configuration ommited, due to complex serialization

    /// Minimum playout delay of subscriber
    public let minPlayoutDelay: UInt32?

    /// Maximum playout delay of subscriber
    public let maxPlayoutDelay: UInt32?

    /// Improves A/V sync when playout_delay set to a value larger than 200ms.
    /// It will disable transceiver re-use so not recommended for rooms with frequent subscription changes
    public let syncStreams: Bool?

    /// Define agents that should be dispatched to this room
    public let agents: [RoomAgentDispatch]?

    enum CodingKeys: String, CodingKey {
        case name
        case emptyTimeout = "empty_timeout"
        case departureTimeout = "departure_timeout"
        case maxParticipants = "max_participants"
        case metadata
        case minPlayoutDelay = "min_playout_delay"
        case maxPlayoutDelay = "max_playout_delay"
        case syncStreams = "sync_streams"
        case agents
    }

    public init(
        name: String? = nil,
        emptyTimeout: UInt32? = nil,
        departureTimeout: UInt32? = nil,
        maxParticipants: UInt32? = nil,
        metadata: String? = nil,
        minPlayoutDelay: UInt32? = nil,
        maxPlayoutDelay: UInt32? = nil,
        syncStreams: Bool? = nil,
        agents: [RoomAgentDispatch]? = nil
    ) {
        self.name = name
        self.emptyTimeout = emptyTimeout
        self.departureTimeout = departureTimeout
        self.maxParticipants = maxParticipants
        self.metadata = metadata
        self.minPlayoutDelay = minPlayoutDelay
        self.maxPlayoutDelay = maxPlayoutDelay
        self.syncStreams = syncStreams
        self.agents = agents
    }
}

public struct RoomAgentDispatch: Encodable, Sendable, Equatable {
    /// Name of the agent to dispatch
    public let agentName: String?

    /// Metadata for the agent
    public let metadata: String?

    enum CodingKeys: String, CodingKey {
        case agentName = "agent_name"
        case metadata
    }

    public init(
        agentName: String? = nil,
        metadata: String? = nil
    ) {
        self.agentName = agentName
        self.metadata = metadata
    }
}
