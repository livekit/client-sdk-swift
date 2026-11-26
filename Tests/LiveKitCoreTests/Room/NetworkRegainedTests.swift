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

private final class ReconnectProbe: RoomDelegate, Sendable {
    let completed = AsyncCompleter<ReconnectMode>(label: "Reconnect completed", defaultTimeout: 30)

    func room(_: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        completed.resume(returning: reconnectMode)
    }
}

/// When the network returns, the room resumes at once. It does not wait for the old connection to fail.
@Suite(.tags(.networking, .e2e), TestLimits.e2e)
struct NetworkRegainedTests {
    @Test func regainedConnectivityResumesTheSession() async throws {
        let probe = ReconnectProbe()
        try await TestEnvironment.withRooms([RoomTestingOptions(delegate: probe)]) { rooms in
            let room = rooms[0]
            let sid = room.localParticipant.sid

            room.connectivityListener(.shared, didUpdate: false)
            room.connectivityListener(.shared, didUpdate: true)

            let mode = try await probe.completed.wait()
            #expect(mode == .quick)
            #expect(room.connectionState == .connected)
            #expect(room.localParticipant.sid == sid, "a resume keeps the participant")
        }
    }
}
