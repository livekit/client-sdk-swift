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
        try await with2Rooms { room1, _ in
            let sid = try await room1.sid()
            print("Room.sid(): \(String(describing: sid))")
            XCTAssert(sid.stringValue.starts(with: "RM_"))
        }
    }

    func testConcurrentMicPublish() async throws {
        try await with2Rooms { room1, _ in
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
    func testAddAudioRenderer() async throws {
        try await with2Rooms { room1, room2 in
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
            let audioFrameWatcher = AudioFrameWatcher(id: "notifier01") { _ in
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
}

actor AudioFrameWatcher: AudioRenderer {
    public let id: String
    private let onReceivedFirstFrame: (_ sid: String) -> Void
    public private(set) var didReceiveFirstFrame: Bool = false

    init(id: String, onReceivedFrame: @escaping (String) -> Void) {
        self.id = id
        onReceivedFirstFrame = onReceivedFrame
    }

    public func reset() {
        didReceiveFirstFrame = false
    }

    private func onDidReceiveFirstFrame() {
        if !didReceiveFirstFrame {
            didReceiveFirstFrame = true
            onReceivedFirstFrame(id)
        }
    }

    nonisolated
    func render(sampleBuffer: CMSampleBuffer) {
        print("did receive first audio frame: \(String(describing: sampleBuffer))")
        Task {
            await onDidReceiveFirstFrame()
        }
    }
}
