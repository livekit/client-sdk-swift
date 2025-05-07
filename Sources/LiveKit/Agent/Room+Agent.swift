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
        // Filter out agents that are replaced by another agent e.g. avatar worker
        let onBehalfIdentities = Set(allParticipants.compactMap {
            $0.value.attributes[publishOnBehalfAttributeKey]
        })
        return allParticipants.filter {
            $0.value.isAgent && !onBehalfIdentities.contains($0.key.stringValue)
        }
    }

    /// Returns the first agent participant or `nil` if there are no agent participants.
    @objc
    var agentParticipant: Participant? {
        agentParticipants.values.first
    }
}
