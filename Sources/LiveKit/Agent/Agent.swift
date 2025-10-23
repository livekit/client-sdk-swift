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

public struct Agent: Loggable {
    // MARK: - Error

    public enum Error: LocalizedError {
        case timeout

        public var errorDescription: String? {
            switch self {
            case .timeout:
                "Agent not connected"
            }
        }
    }

    // MARK: - State

    private enum State {
        case disconnected
        case connecting
        case connected(agentState: AgentState, audioTrack: (any AudioTrack)?, avatarVideoTrack: (any VideoTrack)?)
        case failed(Error)
    }

    private var state: State = .disconnected

    // MARK: - Transitions

    mutating func connecting() {
        switch state {
        case .disconnected:
            state = .connecting
        default:
            log("Invalid transition from \(state) to connecting", .warning)
        }
    }

    mutating func listening() {
        switch state {
        case .disconnected, .connecting:
            state = .connected(agentState: .listening, audioTrack: nil, avatarVideoTrack: nil)
        default:
            log("Invalid transition from \(state) to listening", .warning)
        }
    }

    mutating func connected(participant: Participant) {
        switch state {
        case .connecting, .connected:
            state = .connected(agentState: participant.agentState,
                               audioTrack: participant.audioTracks.first(where: { $0.source == .microphone })?.track as? AudioTrack,
                               avatarVideoTrack: participant.avatarWorker?.firstCameraVideoTrack)
        default:
            log("Invalid transition from \(state) to connected", .warning)
        }
    }

    mutating func failed(_ error: Error) {
        switch state {
        case .disconnected, .connecting, .connected:
            state = .failed(error)
        default:
            log("Invalid transition from \(state) to failed", .warning)
        }
    }

    // MARK: - Public

    public var isConnected: Bool {
        switch state {
        case .connected: true
        default: false
        }
    }

    public var agentState: AgentState? {
        switch state {
        case let .connected(agentState, _, _): agentState
        default: nil
        }
    }

    public var audioTrack: (any AudioTrack)? {
        switch state {
        case let .connected(_, audioTrack, _): audioTrack
        default: nil
        }
    }

    public var avatarVideoTrack: (any VideoTrack)? {
        switch state {
        case let .connected(_, _, avatarVideoTrack): avatarVideoTrack
        default: nil
        }
    }

    public var error: Error? {
        switch state {
        case let .failed(error): error
        default: nil
        }
    }
}

extension AgentState: CustomStringConvertible {
    public var description: String {
        rawValue.capitalized
    }
}
