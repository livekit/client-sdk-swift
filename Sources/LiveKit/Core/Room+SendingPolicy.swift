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

extension Room {
    func isParticipantConnected(_ identity: Participant.Identity) -> Bool {
        allParticipants.contains { $0.key == identity }
    }

    func isParticipantActive(_ identity: Participant.Identity) -> Bool {
        allParticipants.contains { $0.key == identity && $0.value.state == .active }
    }

    func waitUntilActive(_ identity: Participant.Identity) async throws {
        try await activeParticipantCompleters.completer(for: identity.stringValue).wait()
    }

    func validate(_ identity: Participant.Identity, against policy: SendingPolicy?) async throws {
        let isActive = isParticipantActive(identity)
        let policy = policy ?? _state.roomOptions.defaultSendingPolicy
        switch (isActive, policy) {
        case (true, _):
            break
        case (false, .disabled):
            log("Sending to inactive Participant: \(identity.stringValue)", .warning)
        case (false, .throwIfInactive):
            throw LiveKitError(.participantInactive, message: "Participant inactive: \(identity.stringValue)")
        case (false, .waitUntilActive):
            guard isParticipantConnected(identity) else {
                throw LiveKitError(.participantRemoved, message: "Participant removed: \(identity.stringValue)")
            }
            fallthrough
        case (false, .waitUntilConnectedAndActive):
            log("Waiting for inactive Participant: \(identity.stringValue)", .info)
            try await waitUntilActive(identity)
            log("Participant active: \(identity.stringValue)", .info)
            try Task.checkCancellation()
        }
    }
}
