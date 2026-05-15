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

@Suite(.serialized, .tags(.media, .e2e))
struct PublishBufferCapturerTests {
    @Test(arguments: [VideoCodec.vp8])
    func publishBufferTrack(codec: VideoCodec) async throws {
        let publishOptions = VideoPublishOptions(
            simulcast: false,
            preferredCodec: codec,
            preferredBackupCodec: .none,
            degradationPreference: .maintainResolution
        )

        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true), RoomTestingOptions(canSubscribe: true)]) { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            let targetDimensions: Dimensions = .h720_169

            let bufferTrack = LocalVideoTrack.createBufferTrack(
                options: BufferCaptureOptions(dimensions: targetDimensions)
            )

            let bufferCapturer = try #require(bufferTrack.capturer as? BufferCapturer)

            let captureTask = try await createSampleVideoTrack { buffer in
                bufferCapturer.capture(buffer)
            }

            try await room1.localParticipant.publish(videoTrack: bufferTrack, options: publishOptions)

            let publisherIdentity = try #require(room1.localParticipant.identity)
            let remoteParticipant = try #require(room2.remoteParticipants[publisherIdentity])

            // Poll for remote video track subscription
            var remoteVideoTrack: RemoteVideoTrack?
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if let track = remoteParticipant.videoTracks.first?.track as? RemoteVideoTrack {
                    remoteVideoTrack = track
                    break
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }

            let videoTrack = try #require(remoteVideoTrack)

            let videoTrackWatcher = VideoTrackWatcher(id: "watcher01")
            videoTrack.add(videoRenderer: videoTrackWatcher)
            videoTrack.add(delegate: videoTrackWatcher)

            try await videoTrackWatcher.waitForDimensions(targetDimensions, timeout: 120)

            if let preferredCodec = publishOptions.preferredCodec {
                try await videoTrackWatcher.waitForCodec(preferredCodec, timeout: 60)
                #expect(videoTrackWatcher.isCodecDetected(codec: preferredCodec), "Expected codec \(preferredCodec) was not detected")
            }

            try await captureTask.value
        }
    }
}
