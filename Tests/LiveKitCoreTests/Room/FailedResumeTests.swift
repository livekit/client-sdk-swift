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

/// A resume that fails is not repeated: the next attempt rejoins from scratch.
@Suite(.tags(.networking, .e2e), TestLimits.e2e)
struct FailedResumeTests {
    @Test func aFailedResumeIsFollowedByAFullReconnect() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            let validToken = try #require(room._state.token)
            room._state.mutate {
                $0.connectOptions = ConnectOptions(reconnectAttempts: 4,
                                                   reconnectAttemptDelay: 0.1,
                                                   reconnectMaxDelay: 0.2)
                // A resume keeps the token it started with, a full reconnect reads the current one.
                $0.token = "invalid"
            }

            let signalState = await room.signalClient._state
            let onDidMutate = signalState.onDidMutate
            let failedAttempts = StateSync(0)
            signalState.onDidMutate = { state, oldState in
                onDidMutate?(state, oldState)
                guard oldState.connectionState == .reconnecting,
                      state.connectionState == .disconnected,
                      state.disconnectError != nil else { return }
                failedAttempts.mutate { $0 += 1 }
                room._state.mutate { $0.token = validToken }
            }
            defer { signalState.onDidMutate = onDidMutate }

            let sid = room.localParticipant.sid
            try await room.startReconnect(reason: .debug)

            #expect(failedAttempts.copy() == 1)
            #expect(room.connectionState == .connected)
            #expect(room.localParticipant.sid != sid, "a full reconnect joins as a new participant")
        }
    }
}
