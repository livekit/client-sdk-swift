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

import CoreVideo
import Foundation
@testable import LiveKit
import Testing

#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Unpublishing in single PC mode leaves an `inactive` m-section behind, and that section is the
/// only thing the removed `mungeInactiveToRecvOnlyForMedia` ever rewrote — it advertised
/// `recvonly` there, on a transceiver `removeTrack` had already stopped.
///
/// Dropping the rewrite changes what the server sees on unpublish, so this pins the round trip
/// that depends on it: publish, unpublish, publish again, and the subscriber still gets frames.
/// ``RecvOnlyOfferDirectionTests`` covers the SDP locally; this covers the server's half.
///
/// Deliberately uses a small synthetic source rather than `createSampleVideoTrack`: that decodes
/// 1080p at 30fps, and the WebRTC release path other suites are timed against runs on a shared
/// queue this would otherwise saturate.
@Suite(.serialized, .tags(.media))
struct SinglePCRepublishTests {
    private static let width = 320
    private static let height = 240

    /// A frame whose content moves, so the encoder cannot coalesce the stream into one keyframe
    /// and leave the subscriber waiting on a PLI round trip for the rest of the test.
    private static func makePixelBuffer(tick: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attrs, &buffer) == kCVReturnSuccess,
            let pixelBuffer = buffer
        else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        if let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let rows = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            memset(luma, 16, stride * rows)
            let block = 48
            let x = (tick * 7) % max(1, width - block)
            let y = (tick * 5) % max(1, rows - block)
            let pointer = luma.assumingMemoryBound(to: UInt8.self)
            for row in y ..< min(y + block, rows) {
                memset(pointer + row * stride + x, 230, min(block, width - x))
            }
        }
        return pixelBuffer
    }

    @Test(.timeLimit(.minutes(3)))
    func subscriberReceivesFramesAfterUnpublishAndRepublish() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(singlePeerConnection: true, canPublish: true),
            RoomTestingOptions(singlePeerConnection: true, canSubscribe: true),
        ]) { rooms in
            let publisher = rooms[0]
            let subscriber = rooms[1]
            let publisherIdentity = try #require(publisher.localParticipant.identity)

            /// Publishes a moving synthetic track, waits until `subscriber` renders a frame from
            /// it, then tears everything it created back down before returning.
            func publishThenAwaitFramesThenUnpublish(_ label: String) async throws {
                let track = await LocalVideoTrack.createBufferTrack(
                    name: label,
                    source: .camera,
                    options: BufferCaptureOptions(dimensions: Dimensions(width: Int32(Self.width),
                                                                         height: Int32(Self.height))),
                )
                let capturer = try #require(track.capturer as? BufferCapturer)
                let feeder = Task.detached {
                    var tick = 0
                    while !Task.isCancelled {
                        if let pixelBuffer = Self.makePixelBuffer(tick: tick) {
                            capturer.capture(pixelBuffer)
                        }
                        tick += 1
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }

                try await publisher.localParticipant.publish(videoTrack: track)

                let remote = try #require(subscriber.remoteParticipants[publisherIdentity])
                var subscribed: RemoteVideoTrack?
                let subscribeDeadline = Date().addingTimeInterval(45)
                while Date() < subscribeDeadline {
                    if let candidate = remote.videoTracks.first?.track as? RemoteVideoTrack {
                        subscribed = candidate
                        break
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                let remoteTrack = try #require(subscribed, "\(label): never subscribed")

                let watcher = VideoTrackWatcher(id: label)
                remoteTrack.add(videoRenderer: watcher)

                let frameDeadline = Date().addingTimeInterval(45)
                while Date() < frameDeadline, !watcher.didRenderFirstFrame {
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                remoteTrack.remove(videoRenderer: watcher)
                #expect(watcher.didRenderFirstFrame, "\(label): subscribed but no frame rendered")

                // Stop feeding before unpublishing, so the capturer is idle when the transceiver
                // is stopped and nothing of this iteration outlives it.
                feeder.cancel()
                _ = await feeder.result

                let publication = try #require(publisher.localParticipant.videoTracks.first as? LocalTrackPublication)
                try await publisher.localParticipant.unpublish(publication: publication)
            }

            // The first cycle leaves an inactive section with a stopped transceiver behind —
            // the state the munge used to paper over. The second has to work anyway.
            try await publishThenAwaitFramesThenUnpublish("before-unpublish")
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await publishThenAwaitFramesThenUnpublish("after-republish")
        }
    }
}
