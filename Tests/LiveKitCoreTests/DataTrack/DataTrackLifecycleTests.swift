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

/// Data track lifecycle: join-time announcements, publication lifetime, and reconnects.
@Suite(.serialized, .tags(.dataTrack, .e2e), TestLimits.e2e)
struct DataTrackLifecycleTests {
    /// A track published before a participant joins surfaces via the JoinResponse.
    @Test
    func receivesTrackPublishedBeforeJoin() async throws {
        let roomName = UUID().uuidString
        try await TestEnvironment.withRooms([
            RoomTestingOptions(roomName: roomName, canPublishData: true),
        ]) { pubRooms in
            let track = try await pubRooms[0].localParticipant.publishDataTrack(name: "pre-join")

            // The subscriber joins *after* the publish; its watcher is the delegate from creation,
            // so it catches the publish delivered during connect (via the JoinResponse). A distinct
            // identity avoids colliding with the publisher in the same room.
            let watcher = DataTrackWatcher(expectedName: "pre-join")
            try await TestEnvironment.withRooms([
                RoomTestingOptions(delegate: watcher, roomName: roomName, identity: "subscriber", canSubscribe: true),
            ]) { _ in
                let remoteTrack = try await watcher.waitForTrack()
                #expect(remoteTrack.info.name == "pre-join")
            }
            _ = track.isPublished // keep `track` alive across the subscriber's join
        }
    }
}
