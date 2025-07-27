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

public extension Participant {
    @objc
    var isAgent: Bool {
        switch kind {
        case .agent: true
        default: false
        }
    }

    var agentState: AgentState {
        _state.agentAttributes?.lkAgentState ?? .idle
    }

    @objc
    var agentStateString: String {
        agentState.rawValue
    }
}

public extension Participant {
    private var publishingOnBehalf: [Participant.Identity: Participant] {
        guard let _room else { return [:] }
        return _room.allParticipants.filter { $0.value._state.agentAttributes?.lkPublishOnBehalf == identity?.stringValue }
    }

    /// The avatar worker participant associated with the agent.
    @objc
    var avatarWorker: Participant? {
        publishingOnBehalf.values.first
    }
}
