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
import LiveKitWebRTC
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.serialized, .tags(.media, .e2e))
struct SetVideoPublishOptionsTests {
    @Test func updateEncodingWithoutRepublish() async throws {
        try await TestEnvironment.withRoom(RoomTestingOptions(canPublish: true)) { room in
            let bufferTrack = LocalVideoTrack.createBufferTrack(
                name: Track.cameraName,
                source: .camera,
                options: BufferCaptureOptions(dimensions: .h720_169),
            )
            let bufferCapturer = try #require(bufferTrack.capturer as? BufferCapturer)

            let captureTask = try await createSampleVideoTrack { buffer in
                bufferCapturer.capture(buffer)
            }
            defer { captureTask.cancel() }

            let publication = try await room.localParticipant.publish(
                videoTrack: bufferTrack,
                options: VideoPublishOptions(encoding: VideoEncoding(maxBitrate: 1_700_000, maxFps: 30),
                                             simulcast: false),
            )

            let sender = try #require(bufferTrack._state.rtpSender)
            let initialBitrate = try #require(sender.parameters.encodings.first?.maxBitrateBps)
            #expect(initialBitrate.intValue == 1_700_000)
            let sid = publication.sid

            try publication.set(videoPublishOptions: VideoPublishOptions(encoding: VideoEncoding(maxBitrate: 1_200_000, maxFps: 30),
                                                                         simulcast: false))

            let updatedBitrate = try #require(sender.parameters.encodings.first?.maxBitrateBps)
            #expect(updatedBitrate.intValue == 1_200_000)
            // The track was not re-published: same publication, same sender.
            #expect(publication.sid == sid)
            #expect(room.localParticipant.videoTracks.count == 1)
        }
    }

    @Test func rejectsLayerStructureChange() async throws {
        try await TestEnvironment.withRoom(RoomTestingOptions(canPublish: true)) { room in
            let bufferTrack = LocalVideoTrack.createBufferTrack(
                name: Track.cameraName,
                source: .camera,
                options: BufferCaptureOptions(dimensions: .h720_169),
            )
            let bufferCapturer = try #require(bufferTrack.capturer as? BufferCapturer)

            let captureTask = try await createSampleVideoTrack { buffer in
                bufferCapturer.capture(buffer)
            }
            defer { captureTask.cancel() }

            let publication = try await room.localParticipant.publish(
                videoTrack: bufferTrack,
                options: VideoPublishOptions(encoding: VideoEncoding(maxBitrate: 1_700_000, maxFps: 30),
                                             simulcast: false),
            )

            // Toggling simulcast would change the encoding layer structure.
            #expect(throws: LiveKitError.self) {
                try publication.set(videoPublishOptions: VideoPublishOptions(simulcast: true))
            }
        }
    }
}
