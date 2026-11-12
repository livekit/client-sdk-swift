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
}

/// Requires a server with downstream FlexFEC (`rtc.flexfec.downstream_enabled`) and must run in
/// its own process, since FlexFEC is enabled before the peer connection factory is created.
/// Set `LIVEKIT_TESTING_FLEXFEC=1` to run it.
@Suite(.serialized, .tags(.media, .e2e), TestLimits.e2e,
       .enabled(if: ProcessInfo.processInfo.environment["LIVEKIT_TESTING_FLEXFEC"] == "1"))
struct FlexFECTests {
    @Test func subscriberReceivesRepairs() async throws {
        try LiveKitSDK.setFlexFECEnabled(true)

        let publishOptions = VideoPublishOptions(simulcast: false, preferredCodec: .vp8, preferredBackupCodec: .none)

        try await TestEnvironment.withRooms([RoomTestingOptions(isE2eeEnabled: false, canPublish: true),
                                             RoomTestingOptions(isE2eeEnabled: false, canSubscribe: true)])
        { rooms in
            let room1 = rooms[0]
            let room2 = rooms[1]

            let bufferTrack = await LocalVideoTrack.createBufferTrack(options: BufferCaptureOptions(dimensions: .h360_169))
            let bufferCapturer = try #require(bufferTrack.capturer as? BufferCapturer)
            let captureTask = try await createSampleVideoTrack { buffer in
                bufferCapturer.capture(buffer)
            }
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

            func fecPacketsReceived() -> UInt64 {
                videoTrack.statistics?.inboundRtpStream.compactMap(\.fecPacketsReceived).max() ?? 0
            }

            // no repairs until protection is requested
            try await Task.sleep(nanoseconds: 3_000_000_000)
            #expect(fecPacketsReceived() == 0)

            try await videoPublication.set(fecProtection: .fixed(.high))
            #expect(videoPublication.fecProtection == .fixed(.high))

            var received: UInt64 = 0
            let fecDeadline = Date().addingTimeInterval(30)
            while Date() < fecDeadline {
                received = fecPacketsReceived()
                if received > 50 { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            #expect(received > 50, "Expected FlexFEC repairs after requesting high protection, got \(received)")

            try await videoPublication.set(fecProtection: .disabled)
            #expect(videoPublication.fecProtection == .disabled)

            // let in-flight repairs and the stats refresh settle
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let afterDisable = fecPacketsReceived()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            #expect(fecPacketsReceived() == afterDisable, "Expected no FlexFEC repairs after disabling protection")

            captureTask.cancel()
        }
    }
}
