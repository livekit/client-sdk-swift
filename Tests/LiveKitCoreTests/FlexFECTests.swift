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

    @Test func initialSettingsMatchServerSubscription() {
        // without adaptive stream the server starts at high quality, so an update must not lower it
        let manual = TrackSettings.initial(adaptiveStream: false)
        #expect(manual.isEnabled)
        #expect(manual.videoQuality == .high)

        let adaptive = TrackSettings.initial(adaptiveStream: true)
        #expect(!adaptive.isEnabled)
        #expect(adaptive.videoQuality == .low)
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
        #expect(VideoPublishOptions().fecProtection == .disabled)
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
        try await withSubscribedVideo(publishOptions: VideoPublishOptions(simulcast: false, preferredCodec: .vp8, preferredBackupCodec: .none)) { _, _, videoPublication, videoTrack in
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

        try await withSubscribedVideo(publishOptions: publishOptions) { _, localTrack, _, videoTrack in
            func fecPacketsSent() -> UInt64 {
                localTrack.statistics?.outboundRtpStream.compactMap(\.fecPacketsSent).max() ?? 0
            }

            let sent = try await waitFor(above: 50, fecPacketsSent)
            #expect(sent > 50, "Expected FlexFEC repairs sent upstream with fixed high protection, got \(sent)")

            // The server consumes upstream repairs; the subscriber gets none until it requests its own.
            #expect(videoTrack.statistics?.inboundRtpStream.compactMap(\.fecPacketsReceived).max() ?? 0 == 0)
        }
    }

    /// Also covers publishing simulcast with FlexFEC enabled: if a simulcast sender negotiated
    /// FlexFEC, LiveKitWebRTC would abort within seconds in `SendStatisticsProxy`.
    @Test func protectionKeepsSimulcastLayer() async throws {
        let publishOptions = VideoPublishOptions(simulcast: true, preferredCodec: .vp8, preferredBackupCodec: .none)

        try await withSubscribedVideo(publishOptions: publishOptions, dimensions: .h720_169) { _, _, videoPublication, videoTrack in
            func frameWidth() -> UInt64 {
                UInt64(videoTrack.statistics?.inboundRtpStream.compactMap(\.frameWidth).max() ?? 0)
            }

            // the server starts a subscription without adaptive stream at high quality; wait until
            // bandwidth estimation has ramped up to the layer it settles on
            let before = try await waitForSteady(frameWidth)
            #expect(before > 640, "Expected an upper simulcast layer before requesting protection, got \(before)")

            try await videoPublication.set(fecProtection: .fixed(.high))

            // give a layer switch time to show up in the stats
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let after = frameWidth()
            #expect(after >= before, "Requesting protection lowered the received layer from \(before) to \(after)")
        }
    }

    @Test func resubscribeKeepsProtection() async throws {
        let publishOptions = VideoPublishOptions(simulcast: false, preferredCodec: .vp8, preferredBackupCodec: .none)

        try await withSubscribedVideo(publishOptions: publishOptions) { _, _, videoPublication, _ in
            try await videoPublication.set(fecProtection: .fixed(.high))

            try await videoPublication.set(subscribed: false)
            // let the server close the subscription, so the next one starts without protection
            try await Task.sleep(nanoseconds: 5_000_000_000)
            try await videoPublication.set(subscribed: true)

            let videoTrack = try #require(await waitForTrack(videoPublication))
            #expect(videoPublication.fecProtection == .fixed(.high))

            let received = try await waitFor(above: 50) {
                videoTrack.statistics?.inboundRtpStream.compactMap(\.fecPacketsReceived).max() ?? 0
            }
            #expect(received > 50, "Expected FlexFEC repairs after resubscribing, got \(received)")
        }
    }

    /// A paused track stays paused when the publisher revokes and restores access: the server keeps
    /// the subscription's settings, and the replay for the new track must not overwrite them.
    @Test func permissionRestoreKeepsPausedProtectedTrack() async throws {
        let publishOptions = VideoPublishOptions(simulcast: false, preferredCodec: .vp8, preferredBackupCodec: .none)

        try await withSubscribedVideo(publishOptions: publishOptions) { publisherRoom, _, videoPublication, _ in
            try await videoPublication.set(fecProtection: .fixed(.high))
            try await videoPublication.set(enabled: false)

            try await publisherRoom.localParticipant.setTrackSubscriptionPermissions(allParticipantsAllowed: false)
            let deadline = Date().addingTimeInterval(30)
            while videoPublication.track != nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try #require(videoPublication.track == nil, "Expected the track to be removed after revoking access")

            try await publisherRoom.localParticipant.setTrackSubscriptionPermissions(allParticipantsAllowed: true)
            let videoTrack = try #require(await waitForTrack(videoPublication))

            #expect(!videoPublication.isEnabled)
            #expect(videoPublication.fecProtection == .fixed(.high))

            // let the replay reach the server, then check that no video arrives
            try await Task.sleep(nanoseconds: 3_000_000_000)
            func framesReceived() -> UInt {
                videoTrack.statistics?.inboundRtpStream.compactMap(\.framesReceived).max() ?? 0
            }
            let before = framesReceived()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            #expect(framesReceived() == before, "Expected the paused track to stay paused after access was restored")
        }
    }

    private func waitForTrack(_ publication: RemoteTrackPublication) async throws -> RemoteVideoTrack? {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let track = publication.track as? RemoteVideoTrack { return track }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
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

    /// Waits until `value` is non-zero and unchanged for 3 s, or 30 s pass.
    private func waitForSteady(_ value: () -> UInt64) async throws -> UInt64 {
        var current: UInt64 = 0
        var steadySince = Date()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let next = value()
            if next != current {
                current = next
                steadySince = Date()
            } else if current > 0, Date().timeIntervalSince(steadySince) >= 3 {
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return current
    }

    private func withSubscribedVideo(publishOptions: VideoPublishOptions,
                                     dimensions: Dimensions = .h360_169,
                                     _ block: @escaping @Sendable (Room, LocalVideoTrack, RemoteTrackPublication, RemoteVideoTrack) async throws -> Void) async throws
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

            try await block(room1, bufferTrack, videoPublication, videoTrack)
        }
    }
}
