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
/// it for good. A full test run is one process, so they run only on request, in a process of
/// their own. CI does that in its "Test Telemetry Lifecycle" step:
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

    /// A subscriber that may not subscribe: its publications are announced and never attach, so
    /// a subscribe stays pending until something ends it. The core's poll interval is the
    /// observable: fast while a subscribe is pending in the Room, slow once none is.
    private static func withUnattachedPublication(_ body: @escaping @Sendable (_ subscriber: Room, _ publish: @Sendable () async throws -> RemoteTrackPublication,
                                                                               _ pending: @escaping @Sendable () -> Bool) async throws -> Void) async throws
    {
        let room = WeakReference<Room>(), instrument = WeakReference<RTCTelemetry>()
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true), RoomTestingOptions(canSubscribe: false)]) { rooms in
            let publisher = rooms[0], subscriber = rooms[1]
            room.value = subscriber
            instrument.value = try #require(subscriber.rtcTelemetry)
            let scope = try #require(subscriber.telemetryScope)
            let identity = try #require(publisher.localParticipant.identity)
            let publish: @Sendable () async throws -> RemoteTrackPublication = {
                try await publisher.localParticipant.publish(audioTrack: TestAudioTrack())
                try await poll(timeout: 10, for: "the subscriber sees the publication") {
                    subscriber.remoteParticipants[identity]?.trackPublications.isEmpty == false
                }
                return try #require(subscriber.remoteParticipants[identity]?.trackPublications.values.first as? RemoteTrackPublication)
            }
            try await body(subscriber, publish) { scope.statsPollIntervalMs() <= 1000 }
        }
        // The ordering keeps no reference of its own: the Room and its instrument go with the call.
        try await poll(timeout: 10, for: "the Room was released") { room.value == nil }
        try await poll(timeout: 10, for: "its RTC instrument was released") { instrument.value == nil }
    }

    /// A subscribe taken back before its track attaches. No `didUnsubscribe` follows, so the
    /// publication itself must end the pending `lk.subscribe`: left open, the core keeps polling
    /// at its fast interval and ends the span as `timed_out` 30 s later. A subscribe after that
    /// is a new intent, and a cancellation report that arrives after it must not end it.
    @Test func aSubscribeTakenBackBeforeItAttachesIsNotLeftPending() async throws {
        try await Self.withUnattachedPublication { subscriber, publish, pending in
            let publication = try await publish()
            try await poll(timeout: 10, for: "the automatic intent reaches the core") { pending() }
            #expect(publication.track == nil)

            try await publication.set(subscribed: false)
            #expect(!pending())

            try await publication.set(subscribed: true)
            #expect(pending())
            subscriber.rtcTelemetry?.subscribeCancelled(publication) // the report of an earlier unsubscribe, late
            #expect(pending())

            try await publication.set(subscribed: false)
            #expect(!pending())
        }
    }

    /// The other order: the app takes the subscription back before the Room's delegate queue has
    /// delivered the remote publish, which is where the automatic intent starts. The queue is
    /// held here, so the order is fixed. The late start must not reopen `lk.subscribe`, and a
    /// subscribe after that still opens one.
    @Test func aPublishDeliveredAfterTheUnsubscribeDoesNotReopenIt() async throws {
        try await Self.withUnattachedPublication { subscriber, publish, pending in
            let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let armed = StateSync(true)
            subscriber.delegates.notify { _ in
                guard armed.mutate({ let first = $0; $0 = false; return first }) else { return }
                held.signal()
                _ = release.wait(timeout: .now() + 30)
            }
            defer { release.signal() }
            #expect(await Self.signalled(held))

            let publication = try await publish()
            #expect(!pending()) // the publish waits on the held queue: no intent yet
            try await publication.set(subscribed: false)

            release.signal()
            let delivered = DispatchSemaphore(value: 0)
            subscriber.delegates.notify { _ in delivered.signal() } // behind the publish on the same queue
            #expect(await Self.signalled(delivered))
            #expect(!pending())

            try await publication.set(subscribed: true)
            #expect(pending())
        }
    }

    /// An attached track that the app unsubscribes still ends through `didUnsubscribe`.
    @Test func anAttachedSubscriptionEndsThroughTheDelegate() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true), RoomTestingOptions(canSubscribe: true)]) { rooms in
            let publisher = rooms[0], subscriber = rooms[1]
            let scope = try #require(subscriber.telemetryScope)
            try await publisher.localParticipant.publish(audioTrack: TestAudioTrack())
            let identity = try #require(publisher.localParticipant.identity)
            try await poll(timeout: 10, for: "the automatic subscription attaches") {
                (subscriber.remoteParticipants[identity]?.trackPublications.values.first as? RemoteTrackPublication)?.track != nil
            }
            let publication = try #require(subscriber.remoteParticipants[identity]?.trackPublications.values.first as? RemoteTrackPublication)

            try await publication.set(subscribed: false)
            try await poll(timeout: 10, for: "no subscribe is pending after the unsubscribe") { scope.statsPollIntervalMs() > 1000 }
        }
    }

    /// Whether `semaphore` is signalled within 5 s, waited for off the cooperative pool.
    private static func signalled(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
            }
        }
    }
}
