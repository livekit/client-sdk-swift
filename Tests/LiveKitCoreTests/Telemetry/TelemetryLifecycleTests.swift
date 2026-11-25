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
import LiveKitFFI
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// What the Room tells the telemetry core at the edges of a reconnect, through the released
/// core, against `livekit-server --dev`.
///
/// The case needs telemetry on from start to end, and an opt-out anywhere in the process ends
/// it for good. A full test run is one process, so it runs only on request:
///
///     LK_TELEMETRY_LIFECYCLE=1 swift test --filter TelemetryLifecycleTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LK_TELEMETRY_LIFECYCLE"] != nil), .tags(.e2e), TestLimits.e2e)
struct TelemetryLifecycleTests {
    /// `ConnectOptions.reconnectAttempts` is a plain `Int`. A negative count makes the retry
    /// helper run its one final attempt with that count as the attempt number, which the
    /// reconnect span must record without trapping.
    @Test func aNegativeRetryCountStillReconnects() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions()]) { rooms in
            let room = rooms[0]
            _ = try #require(room.telemetryScope, "the attempt is only recorded with telemetry on")
            room._state.mutate {
                $0.connectOptions = ConnectOptions(reconnectAttempts: -1,
                                                   reconnectAttemptDelay: 0.1,
                                                   reconnectMaxDelay: 0.2)
            }

            try await room.startReconnect(reason: .debug)

            #expect(room.connectionState == .connected)
        }
    }
}
