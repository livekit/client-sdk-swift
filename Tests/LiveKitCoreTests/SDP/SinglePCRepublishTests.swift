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

/// Unpublishing in single PC mode leaves an `inactive` m-section behind, and that section is the
/// only thing the removed `mungeInactiveToRecvOnlyForMedia` ever rewrote — it advertised
/// `recvonly` there, on a transceiver `removeTrack` had already stopped.
///
/// Dropping the rewrite changes what the server sees on unpublish, so this pins the round trip
/// that depends on it: publish, unpublish, publish again, and the subscriber still gets frames.
/// `RecvOnlyOfferDirectionTests` covers the SDP locally; this covers the server's half.
@Suite(.serialized, .tags(.media))
struct SinglePCRepublishTests {
    @Test(.timeLimit(.minutes(3)))
    func subscriberReceivesFramesAfterUnpublishAndRepublish() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(singlePeerConnection: true, canPublish: true),
            RoomTestingOptions(singlePeerConnection: true, canSubscribe: true),
        ]) { rooms in
            let publisher = rooms[0]
            let subscriber = rooms[1]
            let publisherIdentity = try #require(publisher.localParticipant.identity)

            /// Publishes a moving-content track and waits until `subscriber` renders a frame
            /// from it, returning the capture task so the caller can stop it.
            func publishAndAwaitFrames(_ label: String) async throws -> (LocalVideoTrack, Task<Void, any Error>) {
                let track = await LocalVideoTrack.createBufferTrack(
                    name: label,
                    source: .camera,
                    options: BufferCaptureOptions(dimensions: .h720_169),
                )
                let capturer = try #require(track.capturer as? BufferCapturer)
                let captureTask = try await createSampleVideoTrack { capturer.capture($0) }

                try await publisher.localParticipant.publish(videoTrack: track)

                let remote = try #require(subscriber.remoteParticipants[publisherIdentity])
                var subscribed: RemoteVideoTrack?
                let deadline = Date().addingTimeInterval(60)
                while Date() < deadline {
                    if let candidate = remote.videoTracks.first?.track as? RemoteVideoTrack {
                        subscribed = candidate
                        break
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                let remoteTrack = try #require(subscribed, "\(label): never subscribed")

                let watcher = VideoTrackWatcher(id: label)
                remoteTrack.add(videoRenderer: watcher)
                remoteTrack.add(delegate: watcher)

                let frameDeadline = Date().addingTimeInterval(60)
                while Date() < frameDeadline, !watcher.didRenderFirstFrame {
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                #expect(watcher.didRenderFirstFrame, "\(label): subscribed but no frame rendered")
                remoteTrack.remove(videoRenderer: watcher)

                return (track, captureTask)
            }

            let (first, firstCapture) = try await publishAndAwaitFrames("before-unpublish")
            firstCapture.cancel()

            // Leaves the section inactive with its transceiver stopped — the state the munge
            // used to paper over.
            try await publisher.localParticipant.unpublish(publication: #require(
                publisher.localParticipant.videoTracks.first as? LocalTrackPublication,
            ))
            _ = first

            // Give the unpublish negotiation time to settle before the next offer.
            try await Task.sleep(nanoseconds: 1_000_000_000)

            let (_, secondCapture) = try await publishAndAwaitFrames("after-republish")
            secondCapture.cancel()
        }
    }
}
