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

/// The audio-device-module counterpart to `TransceiverReleaseTests` in `LiveKitCoreTests`.
///
/// Those tests publish through `TestAudioTrack`, which deliberately bypasses `AudioManager`, so
/// they never start or stop the real ADM. The revert-era crash was reported against the real
/// microphone path, so the stop/release churn has to be exercised there too — that requires a
/// host with granted microphone permission, which is why this lives in the audio target.
@Suite(.serialized, .tags(.audio, .e2e),
       .bug("https://github.com/livekit/client-sdk-swift/issues/1104", "Audio transceivers never released on unpublish"))
struct MicrophoneTransceiverReleaseTests {
    /// Skips rather than fails where the runner has no microphone access, so a host without
    /// permission reports "no ADM coverage" instead of a red result people learn to ignore.
    static var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Reproduces the field repro from
    /// https://github.com/webrtc-sdk/webrtc/pull/194#issuecomment-3241616070 — microphone and a
    /// second video track published together, then `unpublishAll()`, in a loop — against the real
    /// ADM. Two tracks means two transceiver stops racing one debounced renegotiation, so a stop
    /// can land while an offer is in flight; every publish must also start and stop the audio
    /// device for real.
    ///
    /// A buffer-backed video track stands in for the camera so the test needs only microphone
    /// permission, while still contributing the second m-line the overlap depends on.
    /// Cycles to run; `TEST_RUNNER_LK_SOAK=<n>` turns this into the unbounded field repro.
    static var cycles: Int {
        ProcessInfo.processInfo.environment["LK_SOAK"].flatMap(Int.init) ?? 10
    }

    @Test(.enabled(if: hasMicrophonePermission, "Requires microphone permission"))
    func microphoneAndVideoUnpublishAllCycles() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
            let room = rooms[0]
            let participant = room.localParticipant

            let publisher = try #require(room._state.transport?.publisher)
            let baseline = await publisher.unstoppedTransceiverCount

            for _ in 0 ..< Self.cycles {
                let videoTrack = await LocalVideoTrack.createBufferTrack(
                    name: "camera",
                    source: .camera,
                    options: BufferCaptureOptions(dimensions: .h720_169),
                )
                let feeder = (videoTrack.capturer as? BufferCapturer)?.startFeedingFrames(dimensions: .h720_169)

                _ = try await participant.setMicrophone(enabled: true)
                _ = try await participant.publish(videoTrack: videoTrack)

                await participant.unpublishAll()
                feeder?.cancel()
            }

            let unstopped = await publisher.unstoppedTransceiverCount
            #expect(unstopped == baseline, "Expected every published transceiver stopped, found \(unstopped - baseline) unstopped")

            // The ADM must still be usable after all the start/stop churn.
            let republished = try await participant.setMicrophone(enabled: true)
            #expect(republished != nil, "Microphone could not be re-published after the cycles")
        }
    }
}
