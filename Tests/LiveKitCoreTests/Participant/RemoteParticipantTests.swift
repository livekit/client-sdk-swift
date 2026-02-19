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
struct RemoteParticipantTests {
    let timeout: TimeInterval = 0.1

    @Test func waitUntilActiveSuccess() async throws {
        try await TestEnvironment.withRooms(Array(repeating: RoomTestingOptions(), count: 2)) { rooms in
            let active = try #require(rooms[0].remoteParticipants.values.first)

            try await active.waitUntilActive(timeout: timeout)
        }
    }

    @Test func waitUntilActiveTimeout() async throws {
        try await TestEnvironment.withRooms(Array(repeating: RoomTestingOptions(), count: 2)) { rooms in
            let disconnected = try #require(rooms[0].remoteParticipants.values.first)
            disconnected.set(info: .init(), connectionState: .disconnected)

            await #expect(throws: (any Error).self) { try await disconnected.waitUntilActive(timeout: self.timeout) }
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
            let oneDisconnected = try #require(rooms[0].remoteParticipants.values.first)
            oneDisconnected.set(info: .init(), connectionState: .disconnected)

            await #expect(throws: (any Error).self) { try await rooms[0].remoteParticipants.values.waitUntilAllActive(timeout: self.timeout) }
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
            let oneDisconnected = try #require(rooms[0].remoteParticipants.values.first)
            oneDisconnected.set(info: .init(), connectionState: .disconnected)

            try await rooms[0].remoteParticipants.values.waitUntilAnyActive(timeout: timeout)
            try await rooms[1].remoteParticipants.values.waitUntilAnyActive(timeout: timeout)
            try await rooms[2].remoteParticipants.values.waitUntilAnyActive(timeout: timeout)
        }
    }

    @Test func waitUntillAnyActiveTimeout() async throws {
        try await TestEnvironment.withRooms(Array(repeating: RoomTestingOptions(), count: 3)) { rooms in
            let allDisconnected = rooms[0].remoteParticipants.values
            allDisconnected.forEach { $0.set(info: .init(), connectionState: .disconnected) }

            await #expect(throws: (any Error).self) { try await rooms[0].remoteParticipants.values.waitUntilAnyActive(timeout: self.timeout) }
            try await rooms[1].remoteParticipants.values.waitUntilAnyActive(timeout: timeout)
            try await rooms[2].remoteParticipants.values.waitUntilAnyActive(timeout: timeout)
        }
    }
}
