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

/// A `LeaveRequest` with `action == RECONNECT` is the server saying the current session is gone and
/// the client must rejoin from scratch — `IssueFullReconnect` on the server side, raised for a failed
/// negotiation, a publication/subscription error, a dead data channel, a failed move, or a client that
/// cannot migrate.
///
/// The handler stores `.full` and then tears signalling down, and that teardown is what schedules the
/// reconnect. So the stored mode has to survive the scheduling hop: a resume sent after this leave
/// names a participant the server has already dropped, which it can only reject.
@Suite(.serialized, .tags(.networking, .e2e))
struct ServerRequestedFullReconnectTests {
    /// Reproduces the production sequence: the leave arrives on a live signal connection, and the
    /// reconnect it schedules must run `.full` — not the `.quick` that the episode is seeded with.
    @Test func aReconnectLeaveIsNotDowngradedToAResume() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            room._state.mutate {
                $0.connectOptions = ConnectOptions(reconnectAttempts: 3,
                                                   reconnectAttemptDelay: 0.1,
                                                   reconnectMaxDelay: 0.2)
            }

            let observer = ReconnectObserver(attachedTo: room)
            defer { observer.detach() }

            await room.signalClient(room.signalClient,
                                    didReceiveLeave: .reconnect,
                                    reason: .stateMismatch,
                                    regions: nil)

            try await waitForReconnectToSettle(observer)

            // `.quick` is only the seed every episode starts from; the attempt itself must upgrade
            // to `.full`. Before the fix the seed survived and the client resumed a dead session.
            #expect(observer.modes.contains(.full),
                    "server-requested full reconnect was downgraded, modes: \(observer.modes)")
            #expect(room.connectionState == .connected)
        }
    }

    /// The episode is scheduled asynchronously by the signalling teardown, so waiting only for a
    /// settled state would return before it even starts. Wait for it to start, then to finish.
    private func waitForReconnectToSettle(_ observer: ReconnectObserver, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if observer.didFinish { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("reconnect did not settle within \(Int(timeout)) s, modes: \(observer.modes)")
    }
}

/// Records every reconnect mode an episode runs in, and when the episode begins and ends.
private final class ReconnectObserver: Sendable {
    private struct Episode {
        var modes: [ReconnectMode] = []
        var started = false
        var finished = false
    }

    private let state = StateSync(Episode())
    private let room: Room
    private let previous: StateSync<Room.State>.OnDidMutate?

    var modes: [ReconnectMode] { state.copy().modes }
    var didFinish: Bool { state.copy().finished }

    init(attachedTo room: Room) {
        self.room = room
        previous = room._state.onDidMutate
        let previous = previous
        let state = state
        room._state.onDidMutate = { newState, oldState in
            previous?(newState, oldState)
            guard newState.isReconnectingWithMode != oldState.isReconnectingWithMode else { return }
            state.mutate {
                if let mode = newState.isReconnectingWithMode {
                    $0.started = true
                    $0.modes.append(mode)
                } else if $0.started {
                    $0.finished = true
                }
            }
        }
    }

    func detach() {
        room._state.onDidMutate = previous
    }
}
