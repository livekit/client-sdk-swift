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

        public var errorDescription: String? {
            switch self {
            case .timeout:
                "Agent did not connect"
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

    private var state: State = .disconnected

    // MARK: - Transitions

    mutating func disconnected() {
        log("Agent disconnected from \(state)")
        // From any state
        state = .disconnected
    }

    mutating func failed(error: Error) {
        log("Agent failed with error \(error) from \(state)")
        // From any state
        state = .failed(error: error)
    }

    mutating func connecting(buffering: Bool) {
        log("Agent connecting from \(state)")
        switch state {
        case .disconnected, .connecting:
            state = .connecting(buffering: buffering)
        default:
            log("Invalid transition from \(state) to connecting", .warning)
        }
    }

    mutating func connected(participant: Participant) {
        log("Agent connected to \(participant) from \(state)")
        switch state {
        case .connecting, .connected:
            state = .connected(agentState: participant.agentState,
                               audioTrack: participant.agentAudioTrack,
                               avatarVideoTrack: participant.avatarVideoTrack)
        default:
            log("Invalid transition from \(state) to connected", .warning)
        }
    }

    // MARK: - Public

    /// A boolean value indicating whether the agent is connected.
    public var isConnected: Bool {
        switch state {
        case .connected: true
        default: false
        }
    }

    /// The current conversational state of the agent.
    public var agentState: AgentState? {
        switch state {
        case let .connected(agentState, _, _): agentState
        default: nil
        }
    }

    /// The agent's audio track.
    public var audioTrack: (any AudioTrack)? {
        switch state {
        case let .connected(_, audioTrack, _): audioTrack
        default: nil
        }
    }

    /// The agent's avatar video track.
    public var avatarVideoTrack: (any VideoTrack)? {
        switch state {
        case let .connected(_, _, avatarVideoTrack): avatarVideoTrack
        default: nil
        }
    }

    /// The last error that occurred.
    public var error: Error? {
        switch state {
        case let .failed(error): error
        default: nil
        }
    }
}

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
