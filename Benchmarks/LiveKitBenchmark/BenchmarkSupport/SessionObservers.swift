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

import CoreMedia
import CoreVideo
import Foundation
import LiveKit

/// Monotonic milliseconds, the clock every lifecycle metric is measured on.
func nowMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

/// A one-shot latch that records *when* something first happened, so a benchmark can await an
/// event and then subtract timestamps rather than wrapping each step in its own measurement.
final class EventLatch: @unchecked Sendable {
    /// A waiter is keyed so cancellation can settle *its own* continuation, and carries a
    /// `cancelled` state because `withTaskCancellationHandler` can fire its handler before the
    /// operation body has registered anything — the body then settles itself instead of parking a
    /// continuation nobody holds.
    private enum Waiter {
        case waiting(CheckedContinuation<Double, Error>)
        case cancelled
    }

    /// Names the milestone in a timeout, so a failed run says *which* event never arrived rather
    /// than only that one didn't.
    let name: String

    init(_ name: String) {
        self.name = name
    }

    private struct State {
        var fired: Double?
        var waiters: [UInt64: Waiter] = [:]
        var nextWaiterID: UInt64 = 0
    }

    private let _state = StateSync(State())

    /// Records the first occurrence and releases anyone waiting. Later calls are ignored, so a
    /// repeated delegate callback cannot move the mark.
    func fire(at time: Double = nowMs()) {
        let waiters: [Waiter] = _state.mutate { state in
            guard state.fired == nil else { return [] }
            state.fired = time
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for case let .waiting(continuation) in waiters {
            continuation.resume(returning: time)
        }
    }

    /// The timestamp of the first occurrence, waiting up to `timeout` for one.
    func wait(timeout: TimeInterval = 20) async throws -> Double {
        if let fired = _state.read({ $0.fired }) { return fired }

        return try await withThrowingTaskGroup(of: Double.self) { group in
            group.addTask { try await self.awaitFire() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw BenchmarkTimeout(milestone: self.name)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Suspends until ``fire(at:)``, or until cancelled — which is how the timing-out sibling
    /// releases this one.
    ///
    /// The cancellation handler is what makes the timeout observable at all: a checked
    /// continuation does not resume on cancellation by itself, and `withThrowingTaskGroup` cannot
    /// propagate the sibling's `BenchmarkTimeout` until every child has finished. Without it the
    /// group never drains and `wait` hangs for the life of the process instead of reporting which
    /// milestone was missed.
    private func awaitFire() async throws -> Double {
        let id = _state.mutate { state -> UInt64 in
            state.nextWaiterID += 1
            return state.nextWaiterID
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum Settle { case fired(Double), cancelled, parked }
                let settle: Settle = _state.mutate { state in
                    if let fired = state.fired { return .fired(fired) }
                    // The handler already ran: settle here rather than park unreachably.
                    if case .cancelled = state.waiters[id] {
                        state.waiters[id] = nil
                        return .cancelled
                    }
                    state.waiters[id] = .waiting(continuation)
                    return .parked
                }
                switch settle {
                case let .fired(time): continuation.resume(returning: time)
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .parked: break
                }
            }
        } onCancel: {
            let waiter: Waiter? = _state.mutate { state in
                let existing = state.waiters[id]
                state.waiters[id] = .cancelled
                return existing
            }
            // Resumed outside the lock: `fire()` may be running on a delegate thread.
            if case let .waiting(continuation) = waiter {
                _state.mutate { $0.waiters[id] = nil }
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func reset() {
        let waiters: [Waiter] = _state.mutate { state in
            defer { state = State() }
            return Array(state.waiters.values)
        }
        for case let .waiting(continuation) in waiters {
            continuation.resume(throwing: CancellationError())
        }
    }
}

struct BenchmarkTimeout: Error, CustomStringConvertible {
    let milestone: String
    var description: String { "Timed out waiting for lifecycle event '\(milestone)'" }
}

/// Runs one measured iteration, absorbing a failure instead of letting it end the variant.
///
/// The framework treats a thrown iteration as a failed benchmark and discards the variant
/// whole, so a single flaky run costs all 15 samples. That silently biases a comparison: the
/// arm that occasionally fails contributes no row at all rather than a visibly worse one, and
/// its surviving percentiles are read as if nothing had gone wrong. Here a failure costs only
/// its own sample, and is counted so the rate is part of the result.
///
/// - Returns: The milestone that timed out, or `nil` if the iteration completed.
@discardableResult
func runTolerantly(_ iteration: () async throws -> Void) async -> String? {
    do {
        try await iteration()
        return nil
    } catch let timeout as BenchmarkTimeout {
        return timeout.milestone
    } catch {
        return "\(error)"
    }
}

/// Reports a failed iteration, naming the milestone that never arrived.
///
/// Printed rather than only recorded as a metric: the milestone is the useful part and the
/// results table has no column for it. One line per failure — the framework invokes a benchmark
/// body once per iteration, so there is no point in the body at which a per-variant total could
/// be known. Count the lines to get the rate.
func reportFailure(_ milestone: String?, variant: String) {
    guard let milestone else { return }
    print("[\(variant)] iteration failed, never reached: \(milestone)")
}

/// Marks the moment a remote participant becomes visible to an already-connected peer.
final class PeerVisibleObserver: NSObject, RoomDelegate, @unchecked Sendable {
    let visible = EventLatch("peer_visible")

    func room(_: Room, participantDidConnect _: RemoteParticipant) {
        visible.fire()
    }
}

/// Marks the moment a published track is subscribed, and the moment its first frame renders.
///
/// Both are latched from the subscriber side so `pub_to_sub` and `first_frame` are read off one
/// timeline: subscription is a signalling+negotiation event, the first frame is media actually
/// flowing on the established transport.
final class SubscriberObserver: NSObject, RoomDelegate, VideoRenderer, @unchecked Sendable {
    let subscribed = EventLatch("subscribed")
    let firstFrame = EventLatch("first_frame")

    // Not adaptive: the benchmark must not have layers paused out from under it.
    var isAdaptiveStreamEnabled: Bool { false }
    var adaptiveStreamSize: CGSize { CGSize(width: 1280, height: 720) }

    func room(_: Room, participant _: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        subscribed.fire()
        // Attaching here rather than polling keeps the gap between the two latches to the
        // renderer hand-off plus real frame arrival.
        if let track = publication.track as? RemoteVideoTrack {
            track.add(videoRenderer: self)
        }
    }

    nonisolated func render(frame _: VideoFrame) {
        firstFrame.fire()
    }
}

/// Marks the milestones a *late joiner* waits for: each already-published remote track being
/// subscribed, and each subscribed track producing its first frame.
///
/// Separate from ``SubscriberObserver`` because the question is a different one. There, a track is
/// published into an established session and the single first-frame latch is the whole answer.
/// Here the room is already full when the joiner arrives, so what matters is how long until *all*
/// of it is on screen — the "all" latches fire on the last of `expectedTracks` rather than on a
/// timeout, which is what makes a room larger than the preallocated receive sections measurable.
final class LateJoinObserver: NSObject, RoomDelegate, @unchecked Sendable {
    let firstSubscribed = EventLatch("first_subscribed")
    let allSubscribed = EventLatch("all_subscribed")
    let firstFrame = EventLatch("first_frame")
    let allFrames = EventLatch("all_frames")

    private struct State {
        var subscribedCount = 0
        var renderedTrackSids: Set<String> = []
        /// `add(videoRenderer:)` holds the renderer weakly, so the probes live here.
        var probes: [FrameProbe] = []
    }

    private let _state = StateSync(State())
    private let expectedTracks: Int

    init(expectedTracks: Int) {
        self.expectedTracks = expectedTracks
        super.init()
    }

    func room(_: Room, participant _: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let track = publication.track as? RemoteVideoTrack else { return }

        firstSubscribed.fire()
        let subscribed = _state.mutate { state -> Int in
            state.subscribedCount += 1
            return state.subscribedCount
        }
        if subscribed >= expectedTracks { allSubscribed.fire() }

        // One probe per track: a shared renderer could not tell which track a frame came from, so
        // `allFrames` would fire on the first track delivering `expectedTracks` frames.
        let sid = publication.sid.stringValue
        let probe = FrameProbe { [weak self] in self?.recordFrame(trackSid: sid) }
        _state.mutate { $0.probes.append(probe) }
        track.add(videoRenderer: probe)
    }

    private func recordFrame(trackSid: String) {
        firstFrame.fire()
        let rendered = _state.mutate { state -> Int in
            state.renderedTrackSids.insert(trackSid)
            return state.renderedTrackSids.count
        }
        if rendered >= expectedTracks { allFrames.fire() }
    }
}

/// Reports frames from one remote video track, so per-track arrival can be distinguished.
private final class FrameProbe: NSObject, VideoRenderer, @unchecked Sendable {
    private let onFrame: @Sendable () -> Void

    // Not adaptive: the benchmark must not have layers paused out from under it.
    var isAdaptiveStreamEnabled: Bool { false }
    var adaptiveStreamSize: CGSize { CGSize(width: 1280, height: 720) }

    init(onFrame: @escaping @Sendable () -> Void) {
        self.onFrame = onFrame
        super.init()
    }

    nonisolated func render(frame _: VideoFrame) {
        onFrame()
    }
}

/// Marks the arrival of an echoed data payload, for the data round trip.
final class DataEchoObserver: NSObject, RoomDelegate, @unchecked Sendable {
    let received = EventLatch("data_echo")
    private let topic: String

    init(topic: String) {
        self.topic = topic
        super.init()
    }

    func room(_: Room, participant _: RemoteParticipant?, didReceiveData _: Data, forTopic topic: String, encryptionType _: EncryptionType) {
        guard topic == self.topic else { return }
        received.fire()
    }
}

/// Drives a buffer track at ~15fps until cancelled, so subscribers have frames to render.
///
/// The frame counter is what makes the content move, and it is load-bearing. Feeding identical
/// frames looks like it works — the track publishes and bytes flow — but the encoder correctly
/// drops unchanged content, so it emits one keyframe and then nothing. A subscriber cannot decode
/// until the SFU asks the publisher for a fresh keyframe, which turns `subscribed → first frame`
/// into a measurement of that round trip rather than of media latency.
func startFeedingFrames(into track: LocalVideoTrack) -> Task<Void, Never> {
    Task.detached {
        guard let capturer = track.capturer as? BufferCapturer else { return }
        var tick = 0
        while !Task.isCancelled {
            if let pixelBuffer = SyntheticVideo.makePixelBuffer(tick: tick) {
                capturer.capture(pixelBuffer)
            }
            tick += 1
            try? await Task.sleep(nanoseconds: 66_000_000)
        }
    }
}

/// Produces frames for a buffer-backed video track, so the benchmark does not depend on a camera
/// (unavailable, and permission-gated, on a headless bench host).
enum SyntheticVideo {
    /// A mid-grey frame with a bright block whose position follows `tick`.
    ///
    /// The motion is the point: a static frame is encoded once and then dropped, which makes
    /// every downstream measurement a measurement of keyframe-on-demand instead.
    static func makePixelBuffer(width: Int = 640, height: Int = 360, tick: Int = 0) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
            let pixelBuffer
        else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        // Mid-grey luma and neutral chroma: encodes cheaply and stays a valid frame.
        for plane in 0 ..< CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            memset(base, 128, bytes)
        }

        // A block sweeping across the luma plane, so consecutive frames genuinely differ.
        if let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let block = min(96, min(width, lumaHeight) / 3)
            let spanX = max(1, width - block)
            let spanY = max(1, lumaHeight - block)
            let x = abs((tick * 17) % (2 * spanX) - spanX)
            let y = abs((tick * 11) % (2 * spanY) - spanY)
            let pointer = luma.assumingMemoryBound(to: UInt8.self)
            for row in y ..< min(y + block, lumaHeight) {
                memset(pointer + row * stride + x, 230, min(block, width - x))
            }
        }
        return pixelBuffer
    }
}
