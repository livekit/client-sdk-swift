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
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

// swiftformat:disable hoistAwait
@Suite(.serialized, .tags(.e2e))
struct RemoteParticipantTests {
    let timeout: TimeInterval = 0.1

    /// Makes `room` forget that `participant` became active, so `waitUntilActive` has to wait for a
    /// transition that never comes rather than return the cached outcome.
    private func forgetActive(_ participant: RemoteParticipant, in room: Room) async throws {
        let identity = try #require(participant.identity)
        await room.activeParticipantCompleters.completer(for: identity.stringValue).reset()
    }

    @Test func waitUntilActiveSuccess() async throws {
        try await TestEnvironment.withRooms(Array(repeating: RoomTestingOptions(), count: 2)) { rooms in
            let active = try #require(rooms[0].remoteParticipants.values.first)

            try await active.waitUntilActive(timeout: timeout)
        }
    }

    @Test func waitUntilActiveTimeout() async throws {
        try await TestEnvironment.withRooms(Array(repeating: RoomTestingOptions(), count: 2)) { rooms in
            let inactive = try #require(rooms[0].remoteParticipants.values.first)
            try await forgetActive(inactive, in: rooms[0])

            await #expect { try await inactive.waitUntilActive(timeout: self.timeout) } throws: { ($0 as? LiveKitError)?.type == .timedOut }
        }
    }

    @Test func waitUntilAllActiveSuccess() async throws {
        try await TestEnvironment.withRooms(Array(repeating: RoomTestingOptions(), count: 3)) { rooms in
            try await rooms[0].remoteParticipants.values.waitUntilAllActive(timeout: timeout)
            try await rooms[1].remoteParticipants.values.waitUntilAllActive(timeout: timeout)
            try await rooms[2].remoteParticipants.values.waitUntilAllActive(timeout: timeout)
        }
    }

    @Test func waitUntillAllActiveTimeout() async throws {
        try await TestEnvironment.withRooms(Array(repeating: RoomTestingOptions(), count: 3)) { rooms in
            let oneInactive = try #require(rooms[0].remoteParticipants.values.first)
            try await forgetActive(oneInactive, in: rooms[0])

            await #expect { try await rooms[0].remoteParticipants.values.waitUntilAllActive(timeout: self.timeout) } throws: { ($0 as? LiveKitError)?.type == .timedOut }
            try await rooms[1].remoteParticipants.values.waitUntilAllActive(timeout: timeout)
            try await rooms[2].remoteParticipants.values.waitUntilAllActive(timeout: timeout)
        }
    }

    @Test func waitUntilAnyActiveSuccess() async throws {
        try await TestEnvironment.withRooms(Array(repeating: RoomTestingOptions(), count: 3)) { rooms in
            try await rooms[0].remoteParticipants.values.waitUntilAnyActive(timeout: timeout)
            try await rooms[1].remoteParticipants.values.waitUntilAnyActive(timeout: timeout)
            try await rooms[2].remoteParticipants.values.waitUntilAnyActive(timeout: timeout)
        }
    }

    @Test func waitUntillAnyActiveNoTimeout() async throws {
        try await TestEnvironment.withRooms(Array(repeating: RoomTestingOptions(), count: 3)) { rooms in
            let oneInactive = try #require(rooms[0].remoteParticipants.values.first)
            try await forgetActive(oneInactive, in: rooms[0])

            try await rooms[0].remoteParticipants.values.waitUntilAnyActive(timeout: timeout)
            try await rooms[1].remoteParticipants.values.waitUntilAnyActive(timeout: timeout)
            try await rooms[2].remoteParticipants.values.waitUntilAnyActive(timeout: timeout)
        }
    }

    @Test func waitUntillAnyActiveTimeout() async throws {
        try await TestEnvironment.withRooms(Array(repeating: RoomTestingOptions(), count: 3)) { rooms in
            for participant in rooms[0].remoteParticipants.values {
                try await forgetActive(participant, in: rooms[0])
            }

            await #expect { try await rooms[0].remoteParticipants.values.waitUntilAnyActive(timeout: self.timeout) } throws: { ($0 as? LiveKitError)?.type == .timedOut }
            try await rooms[1].remoteParticipants.values.waitUntilAnyActive(timeout: timeout)
            try await rooms[2].remoteParticipants.values.waitUntilAnyActive(timeout: timeout)
        }
    }
}
