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

private final class TopicRecorder: RoomDelegate, Sendable {
    private let _topics = StateSync<Set<String>>([])

    func received(topic: String) -> Bool { _topics.read { $0.contains(topic) } }

    func room(_: Room, participant _: RemoteParticipant?, didReceiveData _: Data, forTopic topic: String, encryptionType _: EncryptionType) {
        _topics.mutate { _ = $0.insert(topic) }
    }
}

/// A full reconnect that lands mid-burst, with the reliable buffer saturated past its 2 MB
/// low-water mark. Pins two teardown behaviours that unit tests can only cover piecewise:
///
/// - The buffered-amount mirror starts over with the replacement channel. Left stale above the
///   mark, nothing could ever lower it (nothing sends, so nothing drains), and every reliable
///   send after the reconnect stalled permanently.
/// - The reliable replay set dies with its sequence counter. Retained writes stamped under the
///   old counter replayed into the new session would trip the receiver's per-publisher dedup
///   gate against the fresh packets stamped from 1 — the marker below would never arrive.
@Suite(.serialized, .tags(.dataChannel, .e2e))
struct FullReconnectDataTests {
    @Test func reliableSendsSurviveFullReconnectUnderLoad() async throws {
        let recorder = TopicRecorder()

        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(delegate: recorder, canSubscribe: true),
        ]) { rooms in
            let sender = rooms[0]

            // Saturate the reliable channel well past the 2 MB mark: ~2.8 MB in flight, so the
            // reconnect tears the channels down with both a loaded mirror and a loaded queue.
            let payload = Data(repeating: 0xAB, count: 14000)
            let burst = Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0 ..< 200 {
                        group.addTask {
                            // Sends interrupted by the teardown fail with the disconnect error;
                            // that is the expected fate of an in-flight burst, not a test failure.
                            try? await sender.localParticipant.publish(
                                data: payload,
                                options: DataPublishOptions(topic: "burst", reliable: true),
                            )
                        }
                    }
                }
            }

            // Mid-burst, not after: the point is tearing down while the buffer is saturated.
            try await Task.sleep(nanoseconds: 200_000_000)
            try await sender.startReconnect(reason: .debug, nextReconnectMode: .full)
            try await poll(timeout: 15, for: "the full reconnect to complete") {
                sender.connectionState == .connected
            }
            burst.cancel()

            // The proof both fixes hold: a fresh reliable send flows through the replacement
            // channel and is not deduped against replayed pre-reconnect sequences.
            try await sender.localParticipant.publish(
                data: payload,
                options: DataPublishOptions(topic: "post-reconnect-marker", reliable: true),
            )
            try await poll(timeout: 15, for: "the post-reconnect marker to arrive") {
                recorder.received(topic: "post-reconnect-marker")
            }
        }
    }
}
