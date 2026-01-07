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

/// Represents a LiveKit Agent.
///
/// The ``Agent`` struct represents the state of a LiveKit agent within a ``Session``.
/// It provides information about the agent's connection status, its current state
/// (e.g., listening, thinking, speaking), and its media tracks.
///
/// The ``Agent``'s properties are updated automatically by the ``Session`` as the agent's
/// state changes. This allows the application to react to the agent's
/// behavior, such as displaying its avatar video or indicating when it is speaking.
/// The ``agentState`` property is particularly useful for building UIs that reflect
/// the agent's current activity.
///
/// - SeeAlso: [LiveKit SwiftUI Agent Starter](https://github.com/livekit-examples/agent-starter-swift).
/// - SeeAlso: [LiveKit Agents documentation](https://docs.livekit.io/agents/).
public struct Agent: Loggable {
    // MARK: - Error

    public enum Error: LocalizedError {
        case timeout
        case left

        public var errorDescription: String? {
            switch self {
            case .timeout:
                "Agent did not connect to the room"
            case .left:
                "Agent left the room unexpectedly"
            }
        }
    }

    // MARK: - State

    private enum State {
        case disconnected
        case connecting(buffering: Bool)
        case connected(agentState: AgentState, audioTrack: (any AudioTrack)?, avatarVideoTrack: (any VideoTrack)?)
        case failed(error: Error)
    }

    private var state: State = .disconnected {
        didSet {
            log("\(oldValue) → \(state)")
        }
    }

    // MARK: - Transitions

    mutating func disconnected() {
        state = .disconnected
    }

    mutating func failed(error: Error) {
        state = .failed(error: error)
    }

    mutating func connecting(buffering: Bool) {
        state = .connecting(buffering: buffering)
    }

    mutating func connected(participant: Participant) {
        state = .connected(agentState: participant.agentState,
                           audioTrack: participant.agentAudioTrack,
                           avatarVideoTrack: participant.avatarVideoTrack)
    }
}

// MARK: - Derived State

public extension Agent {
    /// A boolean value indicating whether the agent is connected to the client.
    ///
    /// Returns `true` when the agent is actively connected and in a conversational state
    /// (listening, thinking, or speaking).
    var isConnected: Bool {
        switch state {
        case let .connected(agentState, _, _):
            switch agentState {
            case .listening, .thinking, .speaking:
                true
            default:
                false
            }
        default:
            false
        }
    }

    /// A boolean value indicating whether the client could be listening for user speech.
    ///
    /// Returns `true` when the agent is in a state where it can receive user input,
    /// either through pre-connect buffering or active conversation states.
    ///
    /// - Note: This may not mean that the agent is actually connected. The audio pre-connect
    ///   buffer could be active and recording user input before the agent actually connects.
    var canListen: Bool {
        switch state {
        case let .connecting(buffering):
            buffering
        case let .connected(agentState, _, _):
            switch agentState {
            case .listening, .thinking, .speaking:
                true
            default:
                false
            }
        default:
            false
        }
    }

    /// A boolean value indicating whether the agent is currently connecting or setting itself up.
    ///
    /// Returns `true` during the connection phase (before pre-connect buffering begins) or
    /// when the agent is initializing after connection.
    var isPending: Bool {
        switch state {
        case let .connecting(buffering):
            !buffering
        case let .connected(agentState, _, _):
            switch agentState {
            case .initializing, .idle:
                true
            default:
                false
            }
        default:
            false
        }
    }

    /// A boolean value indicating whether the client has disconnected from the agent.
    ///
    /// Returns `true` when the agent session has ended, either for an expected or unexpected reason
    /// (including failures).
    var isFinished: Bool {
        switch state {
        case .disconnected, .failed:
            true
        default:
            false
        }
    }

    /// The current conversational state of the agent.
    var agentState: AgentState? {
        switch state {
        case let .connected(agentState, _, _): agentState
        default: nil
        }
    }

    /// The agent's audio track.
    var audioTrack: (any AudioTrack)? {
        switch state {
        case let .connected(_, audioTrack, _): audioTrack
        default: nil
        }
    }

    /// The agent's avatar video track.
    var avatarVideoTrack: (any VideoTrack)? {
        switch state {
        case let .connected(_, _, avatarVideoTrack): avatarVideoTrack
        default: nil
        }
    }

    /// The last error that occurred.
    var error: Error? {
        switch state {
        case let .failed(error): error
        default: nil
        }
    }
}

// MARK: - Extension

private extension Participant {
    var agentAudioTrack: (any AudioTrack)? {
        audioTracks.first(where: { $0.source == .microphone })?.track as? AudioTrack
    }

    var avatarVideoTrack: (any VideoTrack)? {
        avatarWorker?.firstCameraVideoTrack
    }
}

extension AgentState: CustomStringConvertible {
    public var description: String {
        rawValue.capitalized
    }
}
