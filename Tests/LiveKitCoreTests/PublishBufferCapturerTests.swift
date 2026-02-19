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

import AVFoundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.tags(.media, .e2e))
struct PublishBufferCapturerTests {
    @Test func publishBufferTrack() async throws {
        let testCodecs: [VideoCodec] = [.vp8]
        for codec in testCodecs {
            print("Testing with codec: \(codec)")
            let publishOptions = VideoPublishOptions(
                simulcast: false,
                preferredCodec: codec,
                preferredBackupCodec: .none,
                degradationPreference: .maintainResolution
            )
            try await testWith(publishOptions: publishOptions)
        }
    }
}

extension PublishBufferCapturerTests {
    // swiftlint:disable:next function_body_length
    func testWith(publishOptions: VideoPublishOptions) async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true), RoomTestingOptions(canSubscribe: true)]) { rooms in
            // Alias to Rooms
            let room1 = rooms[0]
            let room2 = rooms[1]

            let targetDimensions: Dimensions = .h720_169

            let captureOptions = BufferCaptureOptions(dimensions: targetDimensions)

            let bufferTrack = LocalVideoTrack.createBufferTrack(
                options: captureOptions
            )

            guard let bufferCapturer = bufferTrack.capturer as? BufferCapturer else {
                Issue.record("Expected BufferCapturer")
                return
            }

            let captureTask = try await createSampleVideoTrack { buffer in
                bufferCapturer.capture(buffer)
            }

            try await room1.localParticipant.publish(videoTrack: bufferTrack, options: publishOptions)

            guard let publisherIdentity = room1.localParticipant.identity else {
                Issue.record("Publisher's identity is nil")
                return
            }

            // Get publisher's participant
            guard let remoteParticipant = room2.remoteParticipants[publisherIdentity] else {
                Issue.record("Failed to lookup Publisher (RemoteParticipant)")
                return
            }

            // Poll for remote video track subscription
            var remoteVideoTrack: RemoteVideoTrack?
            let deadline = Date().addingTimeInterval(30)
            print("Waiting for first video track...")
            while Date() < deadline {
                if let track = remoteParticipant.videoTracks.first?.track as? RemoteVideoTrack {
                    remoteVideoTrack = track
                    break
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }

            guard let remoteVideoTrack else {
                Issue.record("RemoteVideoTrack is nil")
                return
            }

            // Received RemoteVideoTrack
            print("remoteVideoTrack: \(String(describing: remoteVideoTrack))")

            let videoTrackWatcher = VideoTrackWatcher(id: "watcher01")
            remoteVideoTrack.add(videoRenderer: videoTrackWatcher)
            remoteVideoTrack.add(delegate: videoTrackWatcher)

            print("Waiting for target dimensions: \(targetDimensions)")
            try await videoTrackWatcher.waitForDimensions(targetDimensions, timeout: 120)
            print("Did render target dimensions: \(targetDimensions)")

            // Verify codec information
            print("Waiting for codec information...")
            if let codec = publishOptions.preferredCodec {
                try await videoTrackWatcher.waitForCodec(codec, timeout: 60)
                print("Detected codecs: \(videoTrackWatcher.detectedCodecs.joined(separator: ", "))")
                #expect(videoTrackWatcher.isCodecDetected(codec: codec), "Expected codec \(codec) was not detected")
            }

            // Wait for video to complete...
            try await captureTask.value
        }
    }
}
