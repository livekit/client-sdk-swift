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

@Suite(.tags(.media))
struct FECProtectionTests {
    @Test func mapsToProtocolModes() {
        #expect(FECProtection.disabled.toPBType().mode == .fecModeDisabled)
        #expect(FECProtection.adaptive.toPBType().mode == .fecModeAdaptive)
        #expect(FECProtection.fixed(.low).toPBType().mode == .fecModeFixed)
        #expect(FECProtection.minimum(.low).toPBType().mode == .fecModeMinimum)
    }

    @Test func mapsToProtocolLevels() {
        #expect(FECProtection.fixed(.low).toPBType().level == .fecLevelLow)
        #expect(FECProtection.fixed(.medium).toPBType().level == .fecLevelMedium)
        #expect(FECProtection.minimum(.high).toPBType().level == .fecLevelHigh)
    }

    @Test func omitsLevelWhenModeIgnoresIt() {
        #expect(!FECProtection.disabled.toPBType().hasLevel)
        #expect(!FECProtection(mode: .adaptive, level: .high).toPBType().hasLevel)
    }

    @Test func equalityIgnoresUnusedLevel() {
        #expect(FECProtection(mode: .adaptive, level: .high) == .adaptive)
        #expect(FECProtection.fixed(.high) == .fixed(.high))
        #expect(FECProtection.fixed(.high) != .fixed(.low))
        #expect(FECProtection.fixed(.high) != .minimum(.high))
    }

    @Test func updateCarriesProtectionOnlyOnceRequested() {
        let unset = Livekit_UpdateTrackSettings.with { _ in }
        #expect(!unset.hasFec)

        let set = Livekit_UpdateTrackSettings.with { $0.fec = FECProtection.minimum(.medium).toPBType() }
        #expect(set.hasFec)
        #expect(set.fec.mode == .fecModeMinimum)
        #expect(set.fec.level == .fecLevelMedium)
    }

    @Test func settingsKeepRequestedProtection() {
        let initial = TrackSettings(enabled: true)
        #expect(initial.fecProtection == nil)

        let requested = initial.copyWith(fecProtection: .value(.fixed(.high)))
        #expect(requested.fecProtection == .fixed(.high))
        #expect(requested.copyWith(preferredFPS: .value(15)).fecProtection == .fixed(.high))
    }

    @Test func initialSettingsMatchServerSubscription() {
        // without adaptive stream the server starts at high quality, so an update must not lower it
        let manual = TrackSettings.initial(adaptiveStream: false, fecProtection: .fixed(.high))
        #expect(manual.isEnabled)
        #expect(manual.videoQuality == .high)
        #expect(manual.fecProtection == .fixed(.high))

        let adaptive = TrackSettings.initial(adaptiveStream: true, fecProtection: nil)
        #expect(!adaptive.isEnabled)
        #expect(adaptive.videoQuality == .low)
        #expect(adaptive.fecProtection == nil)
    }

    @Test func mapsToSenderProtection() {
        let fixed = FECProtection.fixed(.medium).toRTCType()
        #expect(fixed.mode == .fixed)
        #expect(fixed.protectionFactor == 0.25)

        let minimum = FECProtection.minimum(.high).toRTCType()
        #expect(minimum.mode == .minimum)
        #expect(minimum.protectionFactor == 0.35)

        #expect(FECProtection.fixed(.low).toRTCType().protectionFactor == 0.15)
        #expect(FECProtection.adaptive.toRTCType().mode == .adaptive)
        #expect(FECProtection.disabled.toRTCType().mode == .disabled)
        #expect(FECProtection(mode: .adaptive, level: .high).toRTCType().protectionFactor == 0)
    }

    @Test func publishOptionsCompareProtection() {
        #expect(VideoPublishOptions().fecProtection == nil)
        #expect(VideoPublishOptions(fecProtection: .fixed(.high)) == VideoPublishOptions(fecProtection: .fixed(.high)))
        #expect(VideoPublishOptions(fecProtection: .fixed(.high)) != VideoPublishOptions(fecProtection: .fixed(.low)))
        #expect(VideoPublishOptions(fecProtection: .fixed(.high)) != VideoPublishOptions())
    }
}

/// Requires a server with upstream and downstream FlexFEC (`rtc.flexfec.upstream_enabled`,
/// `rtc.flexfec.downstream_enabled`) and must run in its own process, since FlexFEC is enabled
/// before the peer connection factory is created. Set `LIVEKIT_TESTING_FLEXFEC=1` to run it.
@Suite(.serialized, .tags(.media, .e2e), TestLimits.e2e,
       .enabled(if: ProcessInfo.processInfo.environment["LIVEKIT_TESTING_FLEXFEC"] == "1"))
struct FlexFECTests {
    init() {
        // Process-wide, and throws once the peer connection factory exists, i.e. after the first test.
        try? LiveKitSDK.setFlexFECEnabled(true)
    }

    @Test func subscriberReceivesRepairs() async throws {
        try await withSubscribedVideo(publishOptions: VideoPublishOptions(simulcast: false, preferredCodec: .vp8, preferredBackupCodec: .none)) { _, videoPublication, videoTrack in
            func fecPacketsReceived() -> UInt64 {
                videoTrack.statistics?.inboundRtpStream.compactMap(\.fecPacketsReceived).max() ?? 0
            }

            // no repairs until protection is requested
            try await Task.sleep(nanoseconds: 3_000_000_000)
            #expect(fecPacketsReceived() == 0)

            try await videoPublication.set(fecProtection: .fixed(.high))
            #expect(videoPublication.fecProtection == .fixed(.high))

            let received = try await waitFor(above: 50, fecPacketsReceived)
            #expect(received > 50, "Expected FlexFEC repairs after requesting high protection, got \(received)")

            try await videoPublication.set(fecProtection: .disabled)
            #expect(videoPublication.fecProtection == .disabled)

            // let in-flight repairs and the stats refresh settle
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let afterDisable = fecPacketsReceived()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            #expect(fecPacketsReceived() == afterDisable, "Expected no FlexFEC repairs after disabling protection")
        }
    }

    @Test func publisherSendsRepairs() async throws {
        let publishOptions = VideoPublishOptions(simulcast: false, preferredCodec: .vp8, preferredBackupCodec: .none,
                                                 fecProtection: .fixed(.high))

        try await withSubscribedVideo(publishOptions: publishOptions) { localTrack, _, videoTrack in
            func fecPacketsSent() -> UInt64 {
                localTrack.statistics?.outboundRtpStream.compactMap(\.fecPacketsSent).max() ?? 0
            }

            let sent = try await waitFor(above: 50, fecPacketsSent)
            #expect(sent > 50, "Expected FlexFEC repairs sent upstream with fixed high protection, got \(sent)")

            // The server consumes upstream repairs; the subscriber gets none until it requests its own.
            #expect(videoTrack.statistics?.inboundRtpStream.compactMap(\.fecPacketsReceived).max() ?? 0 == 0)
        }
    }

    @Test(.disabled("LiveKitWebRTC aborts in SendStatisticsProxy when FlexFEC is negotiated for a simulcast sender"))
    func protectionKeepsSimulcastLayer() async throws {
        let publishOptions = VideoPublishOptions(simulcast: true, preferredCodec: .vp8, preferredBackupCodec: .none)

        try await withSubscribedVideo(publishOptions: publishOptions, dimensions: .h720_169) { _, videoPublication, videoTrack in
            func frameWidth() -> UInt64 {
                UInt64(videoTrack.statistics?.inboundRtpStream.compactMap(\.frameWidth).max() ?? 0)
            }

            // the server starts a subscription without adaptive stream at the top layer
            let before = try await waitFor(above: 640, frameWidth)
            #expect(before > 640, "Expected the top simulcast layer before requesting protection, got \(before)")

            try await videoPublication.set(fecProtection: .fixed(.high))

            // give a layer switch time to show up in the stats
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let after = frameWidth()
            #expect(after == before, "Requesting protection changed the received layer from \(before) to \(after)")
        }
    }

    @Test func resubscribeKeepsProtection() async throws {
        let publishOptions = VideoPublishOptions(simulcast: false, preferredCodec: .vp8, preferredBackupCodec: .none)

        try await withSubscribedVideo(publishOptions: publishOptions) { _, videoPublication, _ in
            try await videoPublication.set(fecProtection: .fixed(.high))

            try await videoPublication.set(subscribed: false)
            // let the server close the subscription, so the next one starts without protection
            try await Task.sleep(nanoseconds: 5_000_000_000)
            try await videoPublication.set(subscribed: true)

            var resubscribed: RemoteVideoTrack?
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if let track = videoPublication.track as? RemoteVideoTrack {
                    resubscribed = track
                    break
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            let videoTrack = try #require(resubscribed)
            #expect(videoPublication.fecProtection == .fixed(.high))

            let received = try await waitFor(above: 50) {
                videoTrack.statistics?.inboundRtpStream.compactMap(\.fecPacketsReceived).max() ?? 0
            }
            #expect(received > 50, "Expected FlexFEC repairs after resubscribing, got \(received)")
        }
    }

    private func waitFor(above threshold: UInt64, _ value: () -> UInt64) async throws -> UInt64 {
        var current: UInt64 = 0
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            current = value()
            if current > threshold { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return current
    }

    private func withSubscribedVideo(publishOptions: VideoPublishOptions,
                                     dimensions: Dimensions = .h360_169,
                                     _ block: @escaping @Sendable (LocalVideoTrack, RemoteTrackPublication, RemoteVideoTrack) async throws -> Void) async throws
    {
        try await TestEnvironment.withRooms([RoomTestingOptions(isE2eeEnabled: false, canPublish: true),
                                             RoomTestingOptions(isE2eeEnabled: false, canSubscribe: true)])
        { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            let bufferTrack = await LocalVideoTrack.createBufferTrack(options: BufferCaptureOptions(dimensions: dimensions), reportStatistics: true)
            let bufferCapturer = try #require(bufferTrack.capturer as? BufferCapturer)
            let captureTask = try await createSampleVideoTrack { buffer in
                bufferCapturer.capture(buffer)
            }
            defer { captureTask.cancel() }
            try await room1.localParticipant.publish(videoTrack: bufferTrack, options: publishOptions)

            let publisherIdentity = try #require(room1.localParticipant.identity)
            let remoteParticipant = try #require(room2.remoteParticipants[publisherIdentity])

            var publication: RemoteTrackPublication?
            let subscribeDeadline = Date().addingTimeInterval(30)
            while Date() < subscribeDeadline {
                if let pub = remoteParticipant.videoTracks.first as? RemoteTrackPublication, pub.track is RemoteVideoTrack {
                    publication = pub
                    break
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            let videoPublication = try #require(publication)
            let videoTrack = try #require(videoPublication.track as? RemoteVideoTrack)

            try await block(bufferTrack, videoPublication, videoTrack)
        }
    }
}
