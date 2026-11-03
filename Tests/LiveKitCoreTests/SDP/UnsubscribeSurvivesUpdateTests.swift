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

/// Unsubscribing clears the publication's track, which is the same state a section that has
/// never been attached is in. The mid scan runs on participant updates as well as answers, so
/// without a second signal it would read the unsubscribe as a pending subscription and undo it.
@Suite(.serialized, .tags(.e2e, .media), TestLimits.e2e)
struct UnsubscribeSurvivesUpdateTests {
    private static let dimensions: Dimensions = .h180_169

    @Test
    func participantUpdateDoesNotResurrectAnUnsubscribedTrack() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(singlePeerConnection: true, canPublish: true),
            RoomTestingOptions(singlePeerConnection: true, canSubscribe: true),
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

            let publication = try #require(subscriber.remoteParticipants[publisherIdentity]?
                .videoTracks.first as? RemoteTrackPublication)
            try await publication.set(subscribed: false)
            try await poll(timeout: 30, for: "the unsubscribe clears the track") {
                publication.track == nil
            }

            // The scan runs on participant updates, so one has to leave the unsubscribe alone.
            // A second publication is the realistic trigger: it announces a new publication on
            // the same participant, which is exactly when a stale binding would be revisited.
            let second = await LocalVideoTrack.createBufferTrack(name: "second",
                                                                 options: BufferCaptureOptions(dimensions: Self.dimensions))
            let secondCapturer = try #require(second.capturer as? BufferCapturer)
            let secondFeeder = secondCapturer.startFeedingFrames(dimensions: Self.dimensions)
            defer { secondFeeder.cancel() }
            try await publisher.localParticipant.publish(videoTrack: second)

            try await poll(timeout: 30, for: "the subscriber sees the second publication") {
                (subscriber.remoteParticipants[publisherIdentity]?.videoTracks.count ?? 0) >= 2
            }

            // A couple of beats past the update, in case the scan is late rather than absent.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            #expect(publication.track == nil,
                    "a participant update must not resubscribe a track the user unsubscribed from")
            #expect(!publication.isDesired)
        }
    }
}
