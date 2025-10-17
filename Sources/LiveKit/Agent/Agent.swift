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

import Combine
import Foundation

@MainActor
open class Agent: ObservableObject {
    @Published public private(set) var state: AgentState = .idle

    @Published public private(set) var audioTrack: (any AudioTrack)?
    @Published public private(set) var avatarVideoTrack: (any VideoTrack)?

    public let participant: Participant

    public init(participant: Participant) {
        self.participant = participant
        observe(participant)
    }

    private func observe(_ participant: Participant) {
        Task { [weak self] in
            for try await _ in participant.changes {
                guard let self else { return }

                state = participant.agentState
                updateTracks(of: participant)
            }
        }
    }

    private func updateTracks(of participant: Participant) {
        audioTrack = participant.audioTracks.first(where: { $0.source == .microphone })?.track as? AudioTrack
        avatarVideoTrack = participant.avatarWorker?.firstCameraVideoTrack
    }
}

extension AgentState: CustomStringConvertible {
    public var description: String {
        rawValue.capitalized
    }
}
