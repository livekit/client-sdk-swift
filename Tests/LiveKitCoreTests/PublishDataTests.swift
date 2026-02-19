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

@Suite(.tags(.e2e))
struct PublishDataTests {
    // Test with canSubscribe: true
    @Test func publishDataReceiverCanSubscribe() async throws {
        try await _publishDataTest(receiverRoomOptions: RoomTestingOptions(canSubscribe: true))
    }

    // Test with canSubscribe: false
    @Test func publishDataReceiverCanNotSubscribe() async throws {
        try await _publishDataTest(receiverRoomOptions: RoomTestingOptions(canSubscribe: false))
    }

    private func _publishDataTest(receiverRoomOptions: RoomTestingOptions) async throws {
        struct TestDataPayload: Codable {
            let content: String
        }

        try await TestEnvironment.withRooms([RoomTestingOptions(canPublishData: true), receiverRoomOptions]) { rooms in
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
