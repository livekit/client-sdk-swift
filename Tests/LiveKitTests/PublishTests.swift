/*
 * Copyright 2024 LiveKit
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

import Combine
import CoreMedia
@testable import LiveKit
import XCTest

class PublishTests: XCTestCase {
    func testResolveSid() async throws {
        try await withRooms([RoomTestingOptions()]) { rooms in
            // Alias to Room
            let room1 = rooms[0]

            let sid = try await room1.sid()
            print("Room.sid(): \(String(describing: sid))")
            XCTAssert(sid.stringValue.starts(with: "RM_"))
        }
    }

    func testConcurrentMicPublish() async throws {
        try await withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
            // Alias to Room
            let room1 = rooms[0]

            // Lock
            struct State {
                var firstMicPublication: LocalTrackPublication?
            }

            let _state = StateSync(State())

            // Run Tasks concurrently
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 1 ... 100 {
                    group.addTask {
                        let result = try await room1.localParticipant.setMicrophone(enabled: true)

                        if let result {
                            _state.mutate {
                                if let firstMicPublication = $0.firstMicPublication {
                                    XCTAssert(result == firstMicPublication, "Duplicate mic track has been published")
                                } else {
                                    $0.firstMicPublication = result
                                    print("Did publish first mic track: \(String(describing: result))")
                                }
                            }
                        }
                    }
                }

                try await group.waitForAll()
            }
        }
    }

    // Test if possible to receive audio buffer by adding audio renderer to RemoteAudioTrack.
    func testPublishMicrophone() async throws {
        try await withRooms([RoomTestingOptions(canPublish: true), RoomTestingOptions(canSubscribe: true)]) { rooms in
            // Alias to Rooms
            let room1 = rooms[0]
            let room2 = rooms[1]

            // LocalParticipant's identity should not be nil after a sucessful connection
            guard let publisherIdentity = room1.localParticipant.identity else {
                XCTFail("Publisher's identity is nil")
                return
            }

            // Get publisher's participant
            guard let remoteParticipant = room2.remoteParticipants[publisherIdentity] else {
                XCTFail("Failed to lookup Publisher (RemoteParticipant)")
                return
            }

            // Set up expectation...
            let didSubscribeToRemoteAudioTrack = self.expectation(description: "Did subscribe to remote audio track")
            didSubscribeToRemoteAudioTrack.assertForOverFulfill = false

            var remoteAudioTrack: RemoteAudioTrack?

            // Start watching RemoteParticipant for audio track...
            let watchParticipant = remoteParticipant.objectWillChange.sink { _ in
                if let track = remoteParticipant.firstAudioPublication?.track as? RemoteAudioTrack, remoteAudioTrack == nil {
                    remoteAudioTrack = track
                    didSubscribeToRemoteAudioTrack.fulfill()
                }
            }

            // Publish mic
            try await room1.localParticipant.setMicrophone(enabled: true)

            // Wait for track...
            print("Waiting for first audio track...")
            await self.fulfillment(of: [didSubscribeToRemoteAudioTrack], timeout: 30)

            guard let remoteAudioTrack else {
                XCTFail("RemoteAudioTrack is nil")
                return
            }

            // Received RemoteAudioTrack...
            print("remoteAudioTrack: \(String(describing: remoteAudioTrack))")

            // Set up expectation...
            let didReceiveAudioFrame = self.expectation(description: "Did receive audio frame")
            didReceiveAudioFrame.assertForOverFulfill = false

            // Start watching for audio frame...
            let audioFrameWatcher = AudioTrackWatcher(id: "notifier01") { _ in
                didReceiveAudioFrame.fulfill()
            }

            // Attach audio frame watcher...
            remoteAudioTrack.add(audioRenderer: audioFrameWatcher)

            // Wait for audio frame...
            print("Waiting for first audio frame...")
            await self.fulfillment(of: [didReceiveAudioFrame], timeout: 30)

            // Remove audio frame watcher...
            remoteAudioTrack.remove(audioRenderer: audioFrameWatcher)
            // Clean up
            watchParticipant.cancel()
        }
    }

    struct TestDataPayload: Codable {
        let content: String
    }

    func testPublishData() async throws {
        try await withRooms([RoomTestingOptions(canPublish: true), RoomTestingOptions(canSubscribe: true)]) { rooms in
            // Alias to Rooms
            let room1 = rooms[0]
            let room2 = rooms[1]

            let topics = (1 ... 100).map { "topic \($0)" }

            // Create an instance of the struct
            let testData = TestDataPayload(content: UUID().uuidString)

            // Encode the struct into JSON data
            let jsonData = try JSONEncoder().encode(testData)

            // Create Room delegate watcher
            let room2Watcher: RoomWatcher<TestDataPayload> = room2.createWatcher()

            // Publish concurrently
            try await withThrowingTaskGroup(of: Void.self) { group in
                for topic in topics {
                    group.addTask {
                        try await room1.localParticipant.publish(data: jsonData, options: DataPublishOptions(topic: topic))
                    }
                }

                try await group.waitForAll()
            }

            // Wait concurrently
            let result = try await withThrowingTaskGroup(of: TestDataPayload.self, returning: [TestDataPayload].self) { group in
                for topic in topics {
                    group.addTask {
                        try await room2Watcher.didReceiveDataCompleters.completer(for: topic).wait()
                    }
                }

                var result = [TestDataPayload]()
                for try await payload in group {
                    result.append(payload)
                }
                return result
            }

            print("Result: \(result)")
        }
    }
}
