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

@Suite(.serialized, .tags(.media, .e2e))
struct PublishTrackTests {
    @Test func publishWithoutPermissions() async throws {
        try await TestEnvironment.withRoom(RoomTestingOptions(canPublish: false)) { room in
            let audioTrack = LocalAudioTrack.createTrack()

            await #expect(throws: LiveKitError.self) {
                try await room.localParticipant.publish(audioTrack: audioTrack)
            }
        }
    }

    @Test func publishWithDisallowedSource() async throws {
        try await TestEnvironment.withRoom(RoomTestingOptions(canPublish: true, canPublishSources: [.camera])) { room in
            let audioTrack = LocalAudioTrack.createTrack()

            await #expect(throws: LiveKitError.self) {
                try await room.localParticipant.publish(audioTrack: audioTrack)
            }
        }
    }
}
