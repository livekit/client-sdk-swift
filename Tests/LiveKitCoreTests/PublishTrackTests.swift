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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

class PublishTrackTests: LKTestCase {
    func testPublishWithoutPermissions() async throws {
        try await withRooms([RoomTestingOptions(canPublish: false)]) { rooms in
            let room = rooms[0]
            let audioTrack = LocalAudioTrack.createTrack()

            do {
                try await room.localParticipant.publish(audioTrack: audioTrack)
                XCTFail("Publishing without permissions should throw an error")
            } catch let error as LiveKitError {
                XCTAssertEqual(error.type, .insufficientPermissions)
                XCTAssertEqual(error.message, "Participant does not have permission to publish")
            } catch {
                XCTFail("Expected LiveKitError but got \(error)")
            }
        }
    }

    func testPublishWithDisallowedSource() async throws {
        try await withRooms([RoomTestingOptions(canPublish: true, canPublishSources: [.camera])]) { rooms in
            let room = rooms[0]
            let audioTrack = LocalAudioTrack.createTrack()

            do {
                try await room.localParticipant.publish(audioTrack: audioTrack)
                XCTFail("Publishing with disallowed source should throw an error")
            } catch let error as LiveKitError {
                XCTAssertEqual(error.type, .insufficientPermissions)
                XCTAssertEqual(error.message, "Participant does not have permission to publish tracks from this source")
            } catch {
                XCTFail("Expected LiveKitError but got \(error)")
            }
        }
    }
}
