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
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Resolves once the local participant publishes a track for `source` that is not the
/// publication the reconnect was expected to replace.
private final class RepublishWatcher: NSObject, RoomDelegate, @unchecked Sendable {
    private let source: Track.Source
    private let _replacedSid = StateSync<Track.Sid?>(nil)
    private let _completer = AsyncCompleter<LocalTrackPublication>(label: "Re-published track", defaultTimeout: 30)

    init(source: Track.Source) {
        self.source = source
        super.init()
    }

    /// Arms the watcher: from now on, any publication for `source` other than `sid` resolves the wait.
    func expectRepublish(replacing sid: Track.Sid) {
        _replacedSid.mutate { $0 = sid }
    }

    func waitForRepublish() async throws -> LocalTrackPublication {
        try await _completer.wait()
    }

    func room(_: Room, participant _: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        guard publication.source == source,
              let replacedSid = _replacedSid.copy(), publication.sid != replacedSid else { return }
        _completer.resume(returning: publication)
    }
}

/// Records `.stopped` transitions, so a test can distinguish a capture source that was torn
/// down from one that was only detached from its sender.
private final class CapturerStopSpy: VideoCapturerDelegate, @unchecked Sendable {
    private let _stops = StateSync(0)
    var stops: Int { _stops.copy() }

    func capturer(_: VideoCapturer, didUpdate state: VideoCapturer.CapturerState) {
        guard state == .stopped else { return }
        _stops.mutate { $0 += 1 }
    }
}

@Suite(.serialized, .tags(.media, .broadcast, .e2e))
struct RepublishTracksTests {
    /// What a full reconnect is expected to do to a track's capture source.
    enum CaptureOutcome: Sendable {
        /// Screen share sources (broadcast extension IPC, ReplayKit) cannot be restarted
        /// programmatically, so capture has to survive the reconnect.
        case uninterrupted
        /// Any other video source is torn down and started again.
        case restarted
        /// Audio tracks have no video capturer to observe.
        case noCapturer
    }

    struct Scenario: Sendable, CustomTestStringConvertible {
        let source: Track.Source
        let capture: CaptureOutcome
        let makeTrack: @Sendable () async -> LocalTrack

        var testDescription: String { String(describing: source) }
    }

    private static let dimensions: Dimensions = .h720_169

    @Test(arguments: [
        Scenario(source: .microphone, capture: .noCapturer) { TestAudioTrack() },
        Scenario(source: .camera, capture: .restarted) {
            await LocalVideoTrack.createBufferTrack(name: "camera",
                                                    source: .camera,
                                                    options: BufferCaptureOptions(dimensions: dimensions))
        },
        // createBufferTrack defaults to the screen share name and source
        Scenario(source: .screenShareVideo, capture: .uninterrupted) {
            await LocalVideoTrack.createBufferTrack(options: BufferCaptureOptions(dimensions: dimensions))
        },
    ])
    func fullReconnectRepublishesTrack(scenario: Scenario) async throws {
        let watcher = RepublishWatcher(source: scenario.source)

        try await TestEnvironment.withRooms([RoomTestingOptions(delegate: watcher, canPublish: true)]) { rooms in
            let room = rooms[0]

            let track = await scenario.makeTrack()
            let capturer = (track as? LocalVideoTrack)?.capturer as? BufferCapturer

            let stopSpy = CapturerStopSpy()
            capturer?.add(delegate: stopSpy)

            let feeder = capturer.map { startFeeding($0) }
            defer { feeder?.cancel() }

            let publication = try await publish(track, in: room)
            watcher.expectRepublish(replacing: publication.sid)

            try await room.debug_simulate(scenario: .fullReconnect)
            let republished = try await watcher.waitForRepublish()

            #expect(republished.sid != publication.sid)
            #expect(republished.track === track)
            #expect(track._state.trackState == .started)
            #expect(track._state.rtpSender != nil, "Track was not re-attached to the new publisher")

            switch scenario.capture {
            case .uninterrupted:
                #expect(stopSpy.stops == 0, "Screen share capture must survive a full reconnect")
                #expect(capturer?._state.startStopCounter == 1)
            case .restarted:
                #expect(stopSpy.stops == 1, "Only screen share capture should survive a full reconnect")
                #expect(capturer?.captureState == .started)
            case .noCapturer:
                #expect(capturer == nil)
            }
        }
    }

    private func publish(_ track: LocalTrack, in room: Room) async throws -> LocalTrackPublication {
        if let audioTrack = track as? LocalAudioTrack {
            return try await room.localParticipant.publish(audioTrack: audioTrack)
        }
        let videoTrack = try #require(track as? LocalVideoTrack)
        return try await room.localParticipant.publish(videoTrack: videoTrack)
    }

    /// Publishing waits on the capturer's dimensions, and `stopCapture()` resets them, so a
    /// re-published track needs frames to keep arriving for the whole test.
    private func startFeeding(_ capturer: BufferCapturer) -> Task<Void, Never> {
        let dimensions = Self.dimensions
        return Task {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault,
                                Int(dimensions.width),
                                Int(dimensions.height),
                                kCVPixelFormatType_32BGRA,
                                nil,
                                &pixelBuffer)
            guard let pixelBuffer else { return }

            while !Task.isCancelled {
                capturer.capture(pixelBuffer)
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }
}
