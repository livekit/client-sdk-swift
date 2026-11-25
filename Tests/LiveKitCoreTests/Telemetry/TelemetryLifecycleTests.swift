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

/// What the Room tells the telemetry core at the edges of a reconnect and of a manual subscribe,
/// through the released core, against `livekit-server --dev`.
///
/// Both cases need telemetry on from start to end, and an opt-out anywhere in the process ends
/// it for good. A full test run is one process, so they run only on request:
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

    /// A subscribe taken back before its track attaches. No `didUnsubscribe` follows, so the
    /// publication itself must end the pending `lk.subscribe`: left open, the core keeps polling
    /// at its fast interval and ends the span as `timed_out` 30 s later. The core's poll interval
    /// is the observable: fast while a subscribe is pending, slow once none is. A subscribe after
    /// that opens a new span.
    @Test func aSubscribeTakenBackBeforeItAttachesIsNotLeftPending() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true), RoomTestingOptions(canSubscribe: true)]) { rooms in
            let publisher = rooms[0], subscriber = rooms[1]
            let scope = try #require(subscriber.telemetryScope)
            let pending: @Sendable () -> Bool = { scope.statsPollIntervalMs() <= 1000 }

            try await publisher.localParticipant.publish(audioTrack: TestAudioTrack())
            let identity = try #require(publisher.localParticipant.identity)
            try await poll(timeout: 10, for: "the subscriber sees the publication") {
                subscriber.remoteParticipants[identity]?.trackPublications.isEmpty == false
            }
            let publication = try #require(subscriber.remoteParticipants[identity]?.trackPublications.values.first as? RemoteTrackPublication)

            // Leave the automatic subscription once it is attached: that unsubscribe is reported
            // through the delegate, and the next subscribe is the app's own.
            try await poll(timeout: 10, for: "the automatic subscription attaches") { publication.track != nil }
            try await publication.set(subscribed: false)
            try await poll(timeout: 10, for: "no subscribe is pending after the unsubscribe") { !pending() }

            try await publication.set(subscribed: true)
            #expect(pending())
            try #require(publication.track == nil, "the track attached before the subscribe was taken back")
            try await publication.set(subscribed: false)
            #expect(!pending())

            try await publication.set(subscribed: true)
            #expect(pending())
        }
    }
}
