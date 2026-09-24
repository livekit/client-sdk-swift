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

/// Publishes a single layer 720p camera and checks where its video starts.
///
/// libwebrtc drops the first frames of a stream that is too large for its start bitrate and
/// encodes a smaller one instead. From its ~300 kbps default, this camera starts at 320x180.
@Suite(.serialized, .tags(.media, .e2e))
struct VideoStartBitrateE2ETests {
    @Test(arguments: [false, true])
    func startsAtFullResolution(singlePeerConnection: Bool) async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(isE2eeEnabled: false,
                                                                singlePeerConnection: singlePeerConnection,
                                                                canPublish: true)])
        { rooms in
            let room = rooms[0]
            let publisher = try #require(room._state.transport?.publisher)

            let track = await LocalVideoTrack.createBufferTrack(source: .camera,
                                                                options: BufferCaptureOptions(dimensions: .h720_169))
            let capturer = try #require(track.capturer as? BufferCapturer)

            // Publishing waits for one frame to resolve the capture dimensions. That frame reaches
            // no encoder, so no media flows and nothing but the seed moves the estimate until
            // frames resume.
            try capturer.capture(#require(Self.frame(.h720_169, shade: 0)))
            // A 1.7 Mbps target, so the seed is capped at 1 Mbps.
            try await room.localParticipant.publish(videoTrack: track, options: VideoPublishOptions(simulcast: false))

            let estimateBps = try await Self.firstValue(of: "a bandwidth estimate") {
                await Self.statistics(of: publisher).availableOutgoingBitrate
            }
            #expect(await publisher.videoStartBitrateSeed == .seeded(kbps: 1000))
            #expect(estimateBps == 1_000_000)

            let frames = Self.captureFrames(into: capturer, dimensions: .h720_169)
            defer { frames.cancel() }

            let encoded = try await Self.firstValue(of: "an encoded frame") {
                await Self.statistics(of: publisher).encodedFrameDimensions
            }
            #expect(encoded == .h720_169)
        }
    }

    // MARK: - Helpers

    private struct PublisherStatistics {
        let availableOutgoingBitrate: Double?
        let encodedFrameDimensions: Dimensions?
    }

    private static func statistics(of publisher: Transport) async -> PublisherStatistics {
        let report = await publisher.statistics()
        let statistics = TrackStatistics(from: Array(report.statistics.values), prevStatistics: nil)

        let selectedPairId = statistics.transportStats?.selectedCandidatePairId
        let selectedPair = statistics.iceCandidatePair.first { $0.id == selectedPairId }

        let video = statistics.outboundRtpStream.first { $0.kind == "video" && ($0.framesEncoded ?? 0) > 0 }
        let dimensions = video.flatMap { stream in
            stream.frameWidth.flatMap { width in
                stream.frameHeight.map { Dimensions(width: Int32(width), height: Int32($0)) }
            }
        }

        return PublisherStatistics(availableOutgoingBitrate: selectedPair?.availableOutgoingBitrate,
                                   encodedFrameDimensions: dimensions)
    }

    private static func firstValue<T: Sendable>(of description: String,
                                                timeout: TimeInterval = 10,
                                                _ read: @Sendable () async -> T?) async throws -> T
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = await read() { return value }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw LiveKitError(.timedOut, message: "Timed out waiting for \(description)")
    }

    private static func frame(_ dimensions: Dimensions, shade: Int32) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, Int(dimensions.width), Int(dimensions.height),
                            kCVPixelFormatType_32BGRA, attributes, &pixelBuffer)
        guard let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), shade, CVPixelBufferGetDataSize(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private static func captureFrames(into capturer: BufferCapturer, dimensions: Dimensions) -> Task<Void, Never> {
        Task.detached {
            var shade: Int32 = 0
            while !Task.isCancelled {
                shade = (shade + 1) % 256
                if let frame = frame(dimensions, shade: shade) {
                    capturer.capture(frame)
                }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }
}
