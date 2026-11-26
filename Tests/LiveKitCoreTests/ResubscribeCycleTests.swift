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
import LiveKitTestSupport
import Testing

/// Repeated unsubscribe/resubscribe of one track in single peer connection mode.
///
/// The SFU reuses its receive sections instead of allocating one per subscription, which is the
/// shape of CLT-3632: rust-sdks caches the `(mid, stream_id)` pairs it has dispatched and skips a
/// reused section after a few cycles, so `TrackSubscribed` never arrives again.
///
/// Three things this test has to get right. Each of them, when wrong, produced a *different*
/// confident-looking answer about whether the SDK was broken.
///
/// 1. **Assert on a decoded frame, not on `publication.track != nil`.** A non-nil track only means
///    an object is attached. Any change that leaves the previous track in place satisfies a nil
///    check while no media flows at all.
///
/// 2. **Follow the publication's track, and hold it strongly.** Pinning the object captured on
///    entry means a later replacement renders into something the watcher is no longer attached to,
///    so "no frame" reads as a media failure that is really a test bug. Identity must be a strong
///    reference compared with `===`: the publication frees its old track on every unsubscribe, and
///    the replacement is very likely to be allocated at the freed address, so an `ObjectIdentifier`
///    comparison reports "already attached" for a track the watcher never saw. Reset the frame flag
///    on entry rather than on object change, or it stays latched from an earlier cycle.
///
/// 3. **Hold the unsubscribe interval fixed.** It is not a free parameter: it changes what the
///    *server* does. Resubscribing quickly makes the SFU keep two sections and alternate them;
///    leaving a gap makes it reuse a single section. Only the alternating regime exposes a client
///    that resolves a section by a stale `mid`, so a test that waits on a detach — which some
///    builds produce and others do not — silently tests the easy path in one variant and the hard
///    path in another.
/// Serialized: the two intervals each stand up rooms and publish against the same dev server, and
/// running them concurrently makes them compete for its capacity rather than measuring resubscribe.
@Suite(.serialized)
struct ResubscribeCycleTests {
    /// Counts decoded frames and opts **out** of adaptive stream.
    ///
    /// `VideoTrackWatcher` reports `isAdaptiveStreamEnabled = true`, which makes the server's
    /// willingness to send depend on how the SDK judges this renderer's visibility. That is a
    /// second moving part on top of the subscription itself, and it makes a long-interval run
    /// stall intermittently with the section still answered `sendonly`.
    private final class FrameCounter: VideoRenderer, @unchecked Sendable {
        private let seen = StateSync(false)
        var sawFrame: Bool { seen.copy() }
        func reset() { seen.mutate { $0 = false } }
        var isAdaptiveStreamEnabled: Bool { false }
        var adaptiveStreamSize: CGSize { .init(width: 1920, height: 1080) }
        func set(size _: CGSize) {}
        func render(frame _: LiveKit.VideoFrame) { seen.mutate { $0 = true } }
    }

    private struct NoFrameDecoded: Error, CustomStringConvertible {
        let label: String
        var description: String { "\(label): no frame decoded on the publication's current track" }
    }

    private static let cycles = 10

    /// Resubscribing this quickly keeps the SFU alternating between two receive sections, which is
    /// the regime that discriminates: a client resolving a section by a stale `mid` fails here on
    /// the first cycle, while the same client passes when the server settles on reusing a single
    /// section. Observed against `livekit-server --dev` 1.13.10.
    ///
    /// A ~2 s interval, where the server reuses one section, is deliberately **not** covered. It
    /// stalls reproducibly around the ninth cycle on current `main` — track attached, section
    /// answered `sendonly`, no frame for 25 s — which is a separate defect from the one this test
    /// guards and is not adaptive stream (it reproduces with a renderer that opts out). Adding it
    /// here would ship a red test for an unrelated reason.
    static let intervals: [TimeInterval] = [0.2]

    /// The direction the server answered for each m-section, in order.
    ///
    /// Whether a rebind shows up as a direction change decides which libwebrtc rule fires the
    /// track event: `inactive` → `sendonly` trips the pre-existing "started receiving" rule, so
    /// the event arrives without needing webrtc-sdk/webrtc#321.
    fileprivate static func answeredDirections(_ sdp: String) -> String {
        var out: [String] = []
        var kind: String?
        var direction = "?"
        for raw in sdp.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") {
                if let kind { out.append("\(kind):\(direction)") }
                kind = String(line.dropFirst(2).prefix(while: { $0 != " " }))
                direction = "?"
            } else if ["a=inactive", "a=sendonly", "a=recvonly", "a=sendrecv"].contains(line) {
                direction = String(line.dropFirst(2))
            }
        }
        if let kind { out.append("\(kind):\(direction)") }
        return out.joined(separator: ",")
    }

    /// Waits for frames on whatever track a publication currently holds, re-attaching its renderer
    /// across replacements. See notes 1 and 2 on the suite.
    private final class FrameFollower {
        private let publication: RemoteTrackPublication
        private let room: Room
        private let counter = FrameCounter()
        /// Strong, so a freed track's address cannot be recycled under the identity check.
        private var attached: VideoTrack?

        init(publication: RemoteTrackPublication, room: Room) {
            self.publication = publication
            self.room = room
        }

        private func diagnostics() async -> String {
            let sdp = await room._state.transport?.publisher.remoteDescription?.sdp
            return "sameObject=\(attached === (publication.track as? VideoTrack))"
                + " trackAttached=\(publication.track != nil)"
                + " answered=[\(sdp.map(ResubscribeCycleTests.answeredDirections) ?? "-")]"
        }

        /// Returns once a frame has been decoded *since this call*.
        func awaitFrame(_ label: String, timeout: TimeInterval = 25) async throws {
            counter.reset()
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let track = publication.track as? VideoTrack {
                    if attached !== track {
                        if let previous = attached { await previous.remove(videoRenderer: counter) }
                        await track.add(videoRenderer: counter)
                        attached = track
                    }
                    if counter.sawFrame { return }
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            await Issue.record("\(label): no frame decoded within \(Int(timeout))s — \(diagnostics())")
            throw NoFrameDecoded(label: label)
        }
    }

    /// Publishes a buffer-backed video track from `publisher` and returns the publication the
    /// subscriber sees for it, with the capture task the caller must keep alive for frames to flow.
    private static func publishAndLocate(from publisher: Room,
                                         to subscriber: Room) async throws -> (RemoteTrackPublication, Task<Void, any Error>)
    {
        let bufferTrack = await LocalVideoTrack.createBufferTrack(
            options: BufferCaptureOptions(dimensions: .h720_169),
        )
        let bufferCapturer = try #require(bufferTrack.capturer as? BufferCapturer)
        let captureTask = try await createSampleVideoTrack { buffer in
            bufferCapturer.capture(buffer)
        }
        try await publisher.localParticipant.publish(videoTrack: bufferTrack)

        try await poll(timeout: 20, for: "subscriber sees the remote video publication") {
            subscriber.remoteParticipants.values
                .flatMap(\.videoTracks)
                .contains { $0 is RemoteTrackPublication }
        }
        let publication = try #require(subscriber.remoteParticipants.values
            .flatMap(\.videoTracks)
            .compactMap { $0 as? RemoteTrackPublication }
            .first)
        return (publication, captureTask)
    }

    @Test(.timeLimit(.minutes(10)), arguments: ResubscribeCycleTests.intervals)
    func framesResumeOnEveryResubscribe(unsubscribeInterval: TimeInterval) async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(singlePeerConnection: true, canPublish: true),
            RoomTestingOptions(singlePeerConnection: true, canSubscribe: true),
        ]) { rooms in
            let subscriber = rooms[1]
            let (publication, captureTask) = try await Self.publishAndLocate(from: rooms[0], to: subscriber)
            defer { captureTask.cancel() }

            let frames = FrameFollower(publication: publication, room: subscriber)
            try await frames.awaitFrame("initial subscription")

            var observed: [String] = []
            for cycle in 1 ... Self.cycles {
                try await publication.set(subscribed: false)

                // Fixed, never awaited on a detach: whether the track clears here depends on the
                // SDK build, and making the gap depend on that would change the server's section
                // strategy along with it. See note 3.
                let unsubDeadline = Date().addingTimeInterval(unsubscribeInterval)
                var detached = false
                while Date() < unsubDeadline {
                    if publication.track == nil { detached = true }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                let whileUnsubscribed = await subscriber._state.transport?.publisher.remoteDescription?.sdp

                try await publication.set(subscribed: true)
                try await frames.awaitFrame("cycle \(cycle)")

                let resubscribed = await subscriber._state.transport?.publisher.remoteDescription?.sdp
                observed.append("cycle \(cycle): detached=\(detached)"
                    + " unsubbed=[\(whileUnsubscribed.map(Self.answeredDirections) ?? "-")]"
                    + " resubbed=[\(resubscribed.map(Self.answeredDirections) ?? "-")]")
            }

            // Printed on a pass too: which regime ran is the context for any later failure.
            print("[resubscribe] interval=\(unsubscribeInterval)s")
            for line in observed {
                print("[resubscribe] \(line)")
            }
        }
    }
}
