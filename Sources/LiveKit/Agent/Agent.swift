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

public enum Agent {
    public enum Error: LocalizedError {
        case timeout

        public var errorDescription: String? {
            switch self {
            case .timeout:
                "Agent not connected"
            }
        }
    }

    case disconnected
    case connecting
    case connected(AgentState, (any AudioTrack)?, (any VideoTrack)?)
    case failed(Error)

    public var isConnected: Bool {
        switch self {
        case .connected: true
        default: false
        }
    }

    public var audioTrack: (any AudioTrack)? {
        switch self {
        case let .connected(_, audioTrack, _): audioTrack
        default: nil
        }
    }

    public var avatarVideoTrack: (any VideoTrack)? {
        switch self {
        case let .connected(_, _, avatarVideoTrack): avatarVideoTrack
        default: nil
        }
    }

    static func connected(participant: Participant) -> Agent {
        .connected(participant.agentState,
                   participant.audioTracks.first(where: { $0.source == .microphone })?.track as? AudioTrack,
                   participant.avatarWorker?.firstCameraVideoTrack)
    }
}

extension AgentState: CustomStringConvertible {
    public var description: String {
        rawValue.capitalized
    }
}
