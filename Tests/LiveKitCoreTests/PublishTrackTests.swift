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

@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

struct PublishTrackTests {
    @Test func publishWithoutPermissions() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: false)]) { rooms in
            let room = rooms[0]
            let audioTrack = LocalAudioTrack.createTrack()

            do {
                try await room.localParticipant.publish(audioTrack: audioTrack)
                Issue.record("Publishing without permissions should throw an error")
            } catch let error as LiveKitError {
                #expect(error.type == .insufficientPermissions)
                #expect(error.message == "Participant does not have permission to publish")
            } catch {
                Issue.record("Expected LiveKitError but got \(error)")
            }
        }
    }

    @Test func publishWithDisallowedSource() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true, canPublishSources: [.camera])]) { rooms in
            let room = rooms[0]
            let audioTrack = LocalAudioTrack.createTrack()

            do {
                try await room.localParticipant.publish(audioTrack: audioTrack)
                Issue.record("Publishing with disallowed source should throw an error")
            } catch let error as LiveKitError {
                #expect(error.type == .insufficientPermissions)
                #expect(error.message == "Participant does not have permission to publish tracks from this source")
            } catch {
                Issue.record("Expected LiveKitError but got \(error)")
            }
        }
    }
}
