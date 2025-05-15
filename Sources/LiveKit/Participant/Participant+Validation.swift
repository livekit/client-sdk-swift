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
    @objc(ParticipantIdentityValidation)
    enum IdentityValidation: Int, Sendable {
        case disabled
        case throwIfInactive
        case awaitUntilActive
    }
}

extension Room {
    func isParticipantActive(_ identity: Participant.Identity) -> Bool {
        allParticipants.contains { $0.key == identity && $0.value.state == .active }
    }

    func awaitUntilActive(_ identity: Participant.Identity) async throws {
        if isParticipantActive(identity) { return }
        try await activeParticipantCompleters.completer(for: identity.stringValue).wait()
    }

    func validate(_ identity: Participant.Identity, validation: Participant.IdentityValidation?) async throws {
        let isActive = isParticipantActive(identity)
        let validation = validation ?? identityValidation
        switch (isActive, validation) {
        case (false, .disabled):
            log("Participant validation failed for \(identity.stringValue)")
        case (false, .throwIfInactive):
            throw LiveKitError(.participantInactive, message: "Participant validation failed for \(identity.stringValue)")
        case (false, .awaitUntilActive):
            try await awaitUntilActive(identity)
        case (true, _):
            break
        }
    }
}

// Handle the above for [Participant.Identity]
public extension Collection where Element: Sendable {
    func concurrentForEach(_ operation: @Sendable @escaping (Element) async throws -> Void) async rethrows {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for element in self {
                group.addTask {
                    try await operation(element)
                }
            }
            try await group.waitForAll()
        }
    }
}
