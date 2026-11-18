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

/// A binding the room could not use when it arrived has to be picked up later.
///
/// The server names a `mid` → track SID binding in an answer, and the publication that names
/// that track comes from a separate participant update. When the answer lands first there is no
/// publication to attach to, and an answer is the only other thing that scans — so without a
/// scan on participant updates the binding is stranded with no error.
///
/// A publication holding no track is exactly the state that leaves behind, so this drives it
/// directly rather than racing the server into emitting the two messages in the awkward order.
@Suite(.serialized, .tags(.e2e, .media), TestLimits.e2e)
struct ParticipantUpdateRescanTests {
    private static let dimensions: Dimensions = .h180_169

    @Test
    func aParticipantUpdateAttachesABindingTheRoomCouldNotUseYet() async throws {
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

            // The state an answer that outran its publication leaves: the binding is known and
            // the section is bound, but the publication holds no track. `isDesired` stays true —
            // this is not an unsubscribe, which `attachReceivedMedia` deliberately ignores.
            _ = await publication.set(track: nil)
            #expect(publication.track == nil)
            #expect(publication.isDesired)

            // A participant update with no answer behind it, raised *after* the publication was
            // emptied. Publishing again would not do: that renegotiates, and the answer's own
            // scan would reattach regardless of this call. A third participant that publishes
            // nothing moves no media, so the update is all the subscriber receives.
            let roomName = try #require(subscriber.name)
            let bystander = Room(roomOptions: RoomOptions(singlePeerConnection: true))
            defer { Task { await bystander.disconnect() } }
            try await bystander.connect(
                url: TestEnvironment.liveKitServerUrl(),
                token: TestEnvironment.liveKitServerToken(for: roomName,
                                                          identity: "bystander",
                                                          canPublish: false,
                                                          canPublishData: false,
                                                          canPublishSources: [],
                                                          canSubscribe: true),
            )
            try await poll(timeout: 30, for: "the subscriber sees the late participant") {
                subscriber.remoteParticipants.values.contains { $0.identity?.stringValue == "bystander" }
            }

            try await poll(timeout: 30, for: "the rescan reattaches the stranded binding") {
                publication.track != nil
            }
        }
    }
}
