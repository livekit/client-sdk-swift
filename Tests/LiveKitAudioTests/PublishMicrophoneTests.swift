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

import CoreMedia
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.serialized) struct PublishMicrophoneTests {
    @Test func concurrentMicPublish() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
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
                                    #expect(result == firstMicPublication, "Duplicate mic track has been published")
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
    @Test func publishMicrophone() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true), RoomTestingOptions(canSubscribe: true)]) { rooms in
            // Alias to Rooms
            let room1 = rooms[0]
            let room2 = rooms[1]

            // LocalParticipant's identity should not be nil after a sucessful connection
            let publisherIdentity = try #require(room1.localParticipant.identity, "Publisher's identity is nil")

            // Get publisher's participant
            let remoteParticipant = try #require(room2.remoteParticipants[publisherIdentity], "Failed to lookup Publisher (RemoteParticipant)")

            // Publish mic
            try await room1.localParticipant.setMicrophone(enabled: true)

            // Wait for remote audio track using async polling
            let deadline = Date().addingTimeInterval(30)
            var remoteAudioTrack: RemoteAudioTrack?
            while Date() < deadline {
                if let track = remoteParticipant.firstAudioPublication?.track as? RemoteAudioTrack {
                    remoteAudioTrack = track
                    break
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }

            let track = try #require(remoteAudioTrack, "RemoteAudioTrack not found within timeout")
            print("remoteAudioTrack: \(String(describing: track))")

            // Wait for audio frame using confirmation
            try await confirmation("Did receive audio frame") { confirm in
                let audioFrameWatcher = AudioTrackWatcher(id: "notifier01") { _ in
                    confirm()
                }
                track.add(audioRenderer: audioFrameWatcher)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                track.remove(audioRenderer: audioFrameWatcher)
            }
        }
    }
}
