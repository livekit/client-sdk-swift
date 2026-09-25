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
                throw BenchmarkTimeout()
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
    var description: String { "Timed out waiting for a lifecycle event" }
}

/// Marks the moment a remote participant becomes visible to an already-connected peer.
final class PeerVisibleObserver: NSObject, RoomDelegate, @unchecked Sendable {
    let visible = EventLatch()

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
    let subscribed = EventLatch()
    let firstFrame = EventLatch()

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

/// Marks the arrival of an echoed data payload, for the data round trip.
final class DataEchoObserver: NSObject, RoomDelegate, @unchecked Sendable {
    let received = EventLatch()
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

/// Produces frames for a buffer-backed video track, so the benchmark does not depend on a camera
/// (unavailable, and permission-gated, on a headless bench host).
enum SyntheticVideo {
    static func makePixelBuffer(width: Int = 640, height: Int = 360) -> CVPixelBuffer? {
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
        return pixelBuffer
    }
}
