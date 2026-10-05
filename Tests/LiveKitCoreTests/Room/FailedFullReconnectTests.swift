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

/// A full reconnect that fails must not leave the room reading `.connected`.
///
/// `cleanUp(isFullReconnect: true)` keeps `isReconnectingWithMode == .full`, so after a failed
/// full attempt the next retry attempt must run the full reconnect again. When every attempt
/// fails, the room must end disconnected with the error, so the app learns the call is gone.
@Suite(.serialized, .tags(.networking, .e2e))
struct FailedFullReconnectTests {
    @Test func everyFullAttemptFailingEndsDisconnected() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            room._state.mutate {
                $0.connectOptions = ConnectOptions(reconnectAttempts: 3,
                                                   reconnectAttemptDelay: 0.1,
                                                   reconnectMaxDelay: 0.2)
                // Rejected by the server on every attempt.
                $0.token = "invalid"
            }

            try? await room.startReconnect(reason: .debug, nextReconnectMode: .full)

            #expect(room.connectionState == .disconnected)
            #expect(room._state.isReconnectingWithMode == nil)
        }
    }

    @Test func aFullAttemptFailingOnceIsRetriedAndRecovers() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            let validToken = room._state.token
            room._state.mutate {
                $0.connectOptions = ConnectOptions(reconnectAttempts: 3,
                                                   reconnectAttemptDelay: 1,
                                                   reconnectMaxDelay: 1)
                $0.token = "invalid"
            }
            // The first attempt fails; the server accepts the next one.
            Task {
                try await Task.sleep(nanoseconds: 300_000_000)
                room._state.mutate { $0.token = validToken }
            }

            try await room.startReconnect(reason: .debug, nextReconnectMode: .full)

            #expect(room.connectionState == .connected)
            #expect(room._state.sid != nil, "a room reset by the full reconnect's clean-up is not a reconnected room")
        }
    }
}
