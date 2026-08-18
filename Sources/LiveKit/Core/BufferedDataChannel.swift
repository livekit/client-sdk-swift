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

/// Outbound flow control for a single data channel: a local mirror of the bytes WebRTC has
/// yet to drain, a low-water gate the drain consults before each send, and a latch producers
/// can await when they would rather wait than queue.
///
/// Owns no queue and no send policy — those belong to whoever has one (``DataChannelPair``
/// parks senders in FIFO order, `DataTrackFrameSender` drops the oldest frame).
///
/// ## Why the amount is mirrored rather than read back
/// `LKRTCDataChannelDelegate.dataChannel(_:didChangeBufferedAmount:)` reports the number of
/// bytes *drained* since the last report, not the current level: libwebrtc's
/// `SctpDataChannel::MaybeSendOnBufferedAmountChanged` sends a diff, and only once ≥100 KiB
/// has drained or the buffer empties. `LKRTCDataChannel.bufferedAmount` would give the level
/// directly, but it is a `PROXY_SECONDARY_CONSTMETHOD0` getter, so reading it blocks on
/// WebRTC's network thread.
///
/// ## Ownership
/// Deliberately does not hold the `LKRTCDataChannel`. ``DataChannelPair`` keeps both channel
/// references under one lock so that pair readiness stays a single consistent read, and
/// pushes the result here via ``setReady(_:)``.
final class BufferedDataChannel: Sendable, Loggable {
    /// Feed the channel only while the mirror sits at or below this many bytes.
    let lowWaterMark: UInt64

    private struct State {
        var isReady: Bool = false
        var pending: UInt64 = 0
    }

    private let _state = StateSync(State())
    private let _headroom: AsyncCompleter<Void>

    init(label: String, lowWaterMark: UInt64, waitTimeout: TimeInterval = .defaultPublisherDataChannelOpen) {
        self.lowWaterMark = lowWaterMark
        _headroom = AsyncCompleter<Void>(label: "Data channel headroom (\(label))", defaultTimeout: waitTimeout)
    }

    // MARK: - Drain side

    /// Whether WebRTC's outbound buffer is drained enough to accept more bytes. Says nothing
    /// about whether the channel is usable — the drain checks that when it resolves the
    /// channel to send on, so that the check and the send share one decision.
    var hasHeadroom: Bool {
        _state.read { $0.pending <= lowWaterMark }
    }

    /// Bytes accepted by `sendData` and now sitting in WebRTC's queue.
    func didSend(_ byteCount: Int) {
        let hasHeadroom = _state.mutate { state in
            state.pending += UInt64(byteCount)
            return state.pending <= lowWaterMark
        }
        if !hasHeadroom { _headroom.rearm() }
    }

    /// Bytes WebRTC has drained since its last report. Resumes headroom waiters once the
    /// mirror falls back to the mark.
    ///
    /// A report larger than the mirror means the two have drifted — the channel was torn down
    /// with bytes outstanding, or `sendData` returned success for bytes libwebrtc then
    /// discarded. Self-heals to zero rather than trapping, since the mirror is only a gate.
    func didDrain(_ byteCount: UInt64) {
        let (drifted, canSend) = _state.mutate { state -> (Bool, Bool) in
            // A report against an empty mirror is expected right after ``reset(throwing:)``,
            // when the closing channel flushes bytes this mirror has already forgotten, so
            // that case stays quiet.
            let drifted = state.pending > 0 && state.pending < byteCount
            state.pending = state.pending < byteCount ? 0 : state.pending - byteCount
            return (drifted, state.isReady && state.pending <= lowWaterMark)
        }
        if drifted { log("Unexpected buffer size detected", .error) }
        if canSend { _headroom.resume(returning: ()) }
    }

    // MARK: - Owner-driven state

    /// Reported by the owner from `dataChannelDidChangeState`. Gates ``waitForHeadroom(timeout:)``
    /// so a producer never wakes into a channel that cannot accept bytes.
    func setReady(_ isReady: Bool) {
        let canSend = _state.mutate { state in
            state.isReady = isReady
            return state.isReady && state.pending <= lowWaterMark
        }
        if canSend { _headroom.resume(returning: ()) } else { _headroom.rearm() }
    }

    /// The channel is gone or is being swapped: nothing previously queued is outstanding on
    /// its replacement, so the mirror starts over. Waiters fail with `error`, or
    /// `LiveKitError(.cancelled)` when it is `nil`.
    func reset(throwing error: Error? = nil) {
        _state.mutate {
            $0.isReady = false
            $0.pending = 0
        }
        _headroom.reset(throwing: error)
    }

    // MARK: - Producer side

    /// Suspends until the channel is ready and its buffer has drained to the mark, returning
    /// immediately when that is already true.
    ///
    /// Lets a producer apply backpressure before it commits work, rather than handing bytes to
    /// a drain that will park them. Headroom is not reserved: by the time this returns another
    /// sender may have filled the buffer again, so callers that must not overshoot need to
    /// re-check after each write.
    ///
    /// - Throws: `LiveKitError(.timedOut)` if the buffer never drains, `LiveKitError(.cancelled)`
    ///   on task cancellation, or the error passed to ``reset(throwing:)``.
    /// - Note: No in-tree caller yet. The intended one is the data stream writers, which today
    ///   get backpressure implicitly by parking inside `room.send(dataPacket:)`.
    func waitForHeadroom(timeout: TimeInterval? = nil) async throws {
        try await _headroom.wait(timeout: timeout)
    }
}
