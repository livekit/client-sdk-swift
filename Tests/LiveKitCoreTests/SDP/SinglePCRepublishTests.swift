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

/// Unpublishing in single PC mode leaves an `inactive` m-section whose transceiver `removeTrack`
/// has stopped. That section is the only thing the removed `mungeInactiveToRecvOnlyForMedia` ever
/// rewrote, and it advertised `recvonly` for it.
///
/// What that costs is a *later subscription on the same peer connection*: the server takes the
/// offer at its word, binds a remote track to the recycled section, and nothing ever decodes,
/// because a stopped transceiver cannot receive. So the case that matters is the publisher
/// subscribing to someone else after its own unpublish — republishing alone exercises the send
/// path and passes either way.
@Suite(.serialized, .tags(.e2e, .media), TestLimits.e2e)
struct SinglePCRepublishTests {
    private static let dimensions: Dimensions = .h180_169

    @Test
    func subscribesToRemoteVideoAfterLocalUnpublish() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(singlePeerConnection: true, canPublish: true, canSubscribe: true),
            RoomTestingOptions(singlePeerConnection: true, canPublish: true, canSubscribe: true),
        ]) { rooms in
            let first = rooms[0]
            let second = rooms[1]

            // `first` publishes and then unpublishes, leaving the stopped section behind.
            let track = await LocalVideoTrack.createBufferTrack(options: BufferCaptureOptions(dimensions: Self.dimensions))
            let capturer = try #require(track.capturer as? BufferCapturer)
            let feeder = capturer.startFeedingFrames(dimensions: Self.dimensions)
            defer { feeder.cancel() }

            try await first.localParticipant.publish(videoTrack: track)
            let publication = try #require(first.localParticipant.videoTracks.first as? LocalTrackPublication)
            try await first.localParticipant.unpublish(publication: publication)
            feeder.cancel()

            // The unpublish renegotiation is debounced, and the section has to reach the server
            // before the subscription that might be bound onto it. The peer losing the
            // publication is the observable end of that round trip.
            let firstIdentity = try #require(first.localParticipant.identity)
            try await poll(timeout: 15, for: "the unpublish reaches the peer") {
                second.remoteParticipants[firstIdentity]?.videoTracks.isEmpty ?? false
            }

            // Now `second` publishes, and `first` has to receive it — on the same peer connection
            // that still carries the section it just unpublished.
            let remoteTrack = await LocalVideoTrack.createBufferTrack(options: BufferCaptureOptions(dimensions: Self.dimensions))
            let remoteCapturer = try #require(remoteTrack.capturer as? BufferCapturer)
            let remoteFeeder = remoteCapturer.startFeedingFrames(dimensions: Self.dimensions)
            defer { remoteFeeder.cancel() }

            try await second.localParticipant.publish(videoTrack: remoteTrack)

            let secondIdentity = try #require(second.localParticipant.identity)
            try await poll(timeout: 30, for: "first subscribes to second's video") {
                first.remoteParticipants[secondIdentity]?.videoTracks.first?.track is RemoteVideoTrack
            }

            let subscribed = try #require(first.remoteParticipants[secondIdentity]?
                .videoTracks.first?.track as? RemoteVideoTrack)
            let watcher = VideoTrackWatcher(id: "after-unpublish")
            subscribed.add(videoRenderer: watcher)
            defer { subscribed.remove(videoRenderer: watcher) }

            try await poll(timeout: 30, for: "a frame decodes on the recycled connection") {
                watcher.didRenderFirstFrame
            }
        }
    }
}
