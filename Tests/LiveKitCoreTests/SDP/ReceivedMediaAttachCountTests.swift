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

/// One publication must produce exactly one subscription, whichever path identifies it.
///
/// In single PC mode two paths can see the same section: `didAddTrack`, which libwebrtc fires
/// when a transceiver is created, and the `mid` scan. `addSubscribedMediaTrack` is not
/// idempotent — it builds a new track, replaces the publication's and announces again — so if
/// both run the subscriber ends up with two tracks and two events for one publication. Counting
/// the events is the only way to see that; the track still arrives either way, so every other
/// test stays green.
@Suite(.serialized, .tags(.e2e, .media), TestLimits.e2e)
struct ReceivedMediaAttachCountTests {
    private static let dimensions: Dimensions = .h180_169

    /// Counts `didSubscribeTrack` per track SID.
    private final class SubscribeCounter: RoomDelegate, @unchecked Sendable {
        private let counts = StateSync([Track.Sid: Int]())

        func count(for sid: Track.Sid) -> Int { counts.read { $0[sid] ?? 0 } }
        var total: Int { counts.read { $0.values.reduce(0, +) } }

        func room(_: Room, participant _: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
            counts.mutate { $0[publication.sid, default: 0] += 1 }
        }
    }

    @Test(arguments: [true, false])
    func onePublicationSubscribesOnce(singlePeerConnection: Bool) async throws {
        let counter = SubscribeCounter()
        try await TestEnvironment.withRooms([
            RoomTestingOptions(singlePeerConnection: singlePeerConnection, canPublish: true),
            RoomTestingOptions(delegate: counter, singlePeerConnection: singlePeerConnection, canSubscribe: true),
        ]) { rooms in
            let publisher = rooms[0]
            let subscriber = rooms[1]

            let track = await LocalVideoTrack.createBufferTrack(options: BufferCaptureOptions(dimensions: Self.dimensions))
            let capturer = try #require(track.capturer as? BufferCapturer)
            let feeder = capturer.startFeedingFrames(dimensions: Self.dimensions)
            defer { feeder.cancel() }

            try await publisher.localParticipant.publish(videoTrack: track)
            let publisherIdentity = try #require(publisher.localParticipant.identity)

            try await poll(timeout: 30, for: "the subscriber attaches the track") {
                subscriber.remoteParticipants[publisherIdentity]?.videoTracks.first?.track != nil
            }
            let sid = try #require(subscriber.remoteParticipants[publisherIdentity]?.videoTracks.first?.sid)

            // Both paths are asynchronous, so a duplicate can land after the first. Give the
            // slower one time to arrive rather than racing it.
            try await Task.sleep(nanoseconds: 3_000_000_000)

            #expect(counter.count(for: sid) == 1,
                    "one publication produced \(counter.count(for: sid)) subscriptions")
            #expect(counter.total == 1, "unexpected extra subscriptions: \(counter.total)")
        }
    }
}
