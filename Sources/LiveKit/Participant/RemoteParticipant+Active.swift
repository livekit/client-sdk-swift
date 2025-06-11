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

public extension RemoteParticipant {
    func waitUntilActive(timeout: TimeInterval = .defaultParticipantActiveTimeout) async throws {
        let room = try requireRoom()
        let identity = try requireIdentity()
        try await room.activeParticipantCompleters.completer(for: identity.stringValue).wait(timeout: timeout)
    }
}

public extension Collection<RemoteParticipant> {
    func waitUntilAllActive(timeout: TimeInterval = .defaultParticipantActiveTimeout) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for participant in self {
                group.addTask {
                    try await participant.waitUntilActive(timeout: timeout)
                }
            }
            try await group.waitForAll()
        }
    }

    func waitUntilAnyActive(timeout: TimeInterval = .defaultParticipantActiveTimeout) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for participant in self {
                group.addTask {
                    try await participant.waitUntilActive(timeout: timeout)
                }
            }
            for try await _ in group.prefix(1) {
                group.cancelAll()
            }
        }
    }
}
