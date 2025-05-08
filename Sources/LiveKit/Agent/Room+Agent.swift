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

let publishOnBehalfAttributeKey = "lk.publish_on_behalf"

public extension Room {
    /// Returns a dictionary containing all agent participants.
    @objc
    var agentParticipants: [Participant.Identity: Participant] {
        allParticipants.filter(\.value.isAgent)
    }

    @objc
    var agentParticipant: Participant? {
        agentParticipants.values.first
    }

    @objc
    var avatarOrAgentParticipant: Participant? {
        agentParticipants.values.filter { $0.attributes[publishOnBehalfAttributeKey] != nil }.first ?? agentParticipants.values.first
    }
}
