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

/// Reconnect triggers that fire together must start one reconnect.
///
/// The signal client, the transport and the app can each call `startReconnect` at nearly the same
/// time. Only one caller may be admitted: a second admitted caller replaces the retry task of the
/// first, and the cancelled first caller then disconnects the room that the second is reconnecting.
@Suite(.tags(.networking, .e2e), TestLimits.e2e)
struct ReconnectAdmissionTests {
    @Test func concurrentTriggersStartOneReconnect() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = try #require(rooms.first)
            let participantSid = try #require(room.localParticipant.sid)

            let onDidMutate = room._state.onDidMutate
            let startedReconnects = StateSync(0)
            room._state.onDidMutate = { state, oldState in
                onDidMutate?(state, oldState)
                if oldState.isReconnectingWithMode == nil, state.isReconnectingWithMode != nil {
                    startedReconnects.mutate { $0 += 1 }
                }
            }
            defer { room._state.onDidMutate = onDidMutate }

            let callers = 32
            // Callers wait here until all of them run, so they reach the admission together.
            let waitingCallers = StateSync(0)

            // `startReconnect` returns normally for the admitted caller, also when its reconnect fails.
            let admittedCallers = await withTaskGroup(of: Bool.self) { group in
                for _ in 0 ..< callers {
                    group.addTask {
                        waitingCallers.mutate { $0 += 1 }
                        while waitingCallers.copy() < callers {
                            await Task.yield()
                        }
                        do {
                            try await room.startReconnect(reason: .debug)
                            return true
                        } catch let error as LiveKitError where error.type == .invalidState {
                            return false
                        } catch {
                            Issue.record("a rejected caller must throw invalidState, not \(error)")
                            return false
                        }
                    }
                }
                return await group.reduce(into: 0) { count, isAdmitted in
                    if isAdmitted { count += 1 }
                }
            }

            #expect(admittedCallers == 1)
            #expect(startedReconnects.copy() == 1)
            #expect(room.connectionState == .connected)
            #expect(room._state.isReconnectingWithMode == nil)
            #expect(room.localParticipant.sid == participantSid)
        }
    }
}
