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

// swiftlint:disable file_length

import Foundation

internal import LiveKitWebRTC

// MARK: - Drain

/// One data channel's outbound drain: the queue, its overflow policy, the buffered-amount gate and
/// the per-channel ``SendStage``, with every mutation serialized through a private FIFO event loop.
///
/// ## Delegate
/// The drain *is* the channel's `LKRTCDataChannelDelegate`, so buffered-amount and state callbacks
/// land on the object that owns the affected state — no dispatching on channel labels. What it does
/// not own it forwards to its creator: inbound messages via `onMessage`, readiness via
/// `onStateChange`. (The shape of `DataChannelManager` in client-sdk-android, its channel's
/// `DataChannel.Observer` with a forwarding listener.)
///
/// ## Concurrency
/// `@unchecked Sendable`. `_state` is lock-guarded; everything else (queue, meter, stage, the
/// loop's mirrors) lives in the subscription state, touched only by its single observer.
final class DataChannelDrain<Stage: SendStage>: NSObject, LKRTCDataChannelDelegate, @unchecked Sendable, Loggable {
    // MARK: - Public

    var isOpen: Bool {
        _state.read { $0.sendTarget?.isOpen == true }
    }

    // MARK: - Private

    /// Lock-guarded: `isOpen` and the delegate-hook identity guard read it from arbitrary threads.
    /// The loop keeps its own mirror in `LoopState` (fed by `.attached`) so dispatch never takes
    /// this lock per write.
    private struct State {
        /// The channel in production; a fake in tests (see ``attach(sendTarget:)``).
        var sendTarget: DrainSendChannel?
        /// Set by ``reset(throwing:)``, cleared on attach: separates SDK-initiated teardown from
        /// libwebrtc closing the channel on its own.
        var wasReset: Bool = false
    }

    private struct LoopState {
        var queue = WriteQueue()
        var meter: BufferedAmountMeter
        var stage: Stage
        /// Mirror of `State.sendTarget` (via `.attached`/`.fail`, FIFO-ordered with the writes it
        /// governs) so dispatch takes no lock per write.
        var sendTarget: DrainSendChannel?
        /// `0` disables the size guard. Mirrored here for the same reason (via `.configured`).
        var maxMessageSize: UInt64
        /// Writes dropped under backpressure, logged periodically rather than per drop.
        var dropped: Int = 0
        /// Last reported buffer status, so only transitions are published.
        var wasLow: Bool = true
        /// Reused across `prepare`/`makeWrites` calls. Live here rather than on the drain so that
        /// only the loop's single observer can reach them.
        var scratch: [PreparedBytes] = []
        var writes: [ReadyWrite] = []
    }

    private enum Event {
        /// Work to prepare and queue.
        case submitted(Stage.Input, CheckedContinuation<Void, any Error>?)
        case commanded(Stage.Command)
        case drained(UInt64)
        /// A channel was attached or swapped: the mirror starts over, and under
        /// ``SendOverflow/dropOldest`` anything queued for the previous channel is dropped.
        case attached(DrainSendChannel?)
        /// The negotiated max-message-size changed (at most once per SDP negotiation).
        case configured(maxMessageSize: UInt64)
        case wakeup
        /// The channel is gone for good: fail everything queued for it and reset the stage.
        case fail(Error?)
    }

    /// Matches `lossyDataDropCount % 100` in client-sdk-js: enough to notice sustained loss without
    /// a line per drop.
    private static var dropLogInterval: Int { 100 }

    /// Names the channel in this drain's log lines, since one session runs three drains.
    private let label: String
    private let overflow: SendOverflow
    private let onMessage: @Sendable (Data) -> Void
    private let onStateChange: @Sendable (LKRTCDataChannel) -> Void
    /// Called on a transition only, never per change in the amount buffered.
    private let onBufferStatusChange: @Sendable (Bool) -> Void

    private let _state = StateSync(State())
    private let eventContinuation: AsyncStream<Event>.Continuation
    /// Assigned once in `init`, before the drain escapes — it cannot be a `let` because
    /// `subscribe` needs a fully initialized `self`. Never read or reassigned afterwards; it is
    /// held so that its `deinit` cancels the loop.
    private var eventLoopTask: AnyTaskCancellable?

    init(
        label: String,
        lowWaterMark: UInt64,
        overflow: SendOverflow,
        stage: Stage,
        maxMessageSize: UInt64 = 0,
        onMessage: @escaping @Sendable (Data) -> Void = { _ in },
        onStateChange: @escaping @Sendable (LKRTCDataChannel) -> Void = { _ in },
        onBufferStatusChange: @escaping @Sendable (Bool) -> Void = { _ in },
    ) {
        self.label = label
        self.overflow = overflow
        self.onMessage = onMessage
        self.onStateChange = onStateChange
        self.onBufferStatusChange = onBufferStatusChange

        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        eventContinuation = continuation

        super.init()

        let initial = LoopState(
            meter: BufferedAmountMeter(lowWaterMark: lowWaterMark),
            stage: stage,
            maxMessageSize: maxMessageSize,
        )
        eventLoopTask = events.subscribe(self, state: initial) { drain, event, state in
            drain.process(event, state: &state)
        }
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: - Owner API

    /// Attaches the channel this drain sends on, takes over its delegate slot (detaching the
    /// replaced channel; the identity guard on the hooks backstops callbacks already in flight),
    /// and reports the channel's current state through `onStateChange` — so an owner never probes
    /// `readyState` itself to cover a channel that opened before its delegate landed.
    /// Under ``SendOverflow/park`` anything queued survives the swap and ships on the new channel
    /// (what makes a fast reconnect lossless); under ``SendOverflow/dropOldest`` it is stale and
    /// discarded.
    func setChannel(_ channel: LKRTCDataChannel?) {
        let previous = _state.mutate { state -> DrainSendChannel? in
            let previous = state.sendTarget
            state.sendTarget = channel
            if channel != nil { state.wasReset = false }
            return previous
        }
        if let previous = previous as? LKRTCDataChannel, previous !== channel, previous.delegate === self {
            previous.delegate = nil
        }
        if previous !== channel { parkChannelRelease(previous) }
        channel?.delegate = self
        eventContinuation.yield(.attached(channel))
        if let channel {
            onStateChange(channel)
        }
    }

    /// Attaches what writes go to. A test seam: production goes through ``setChannel(_:)``, which
    /// also owns the delegate slot and the readiness report.
    func attach(sendTarget: DrainSendChannel?) {
        _state.mutate {
            $0.sendTarget = sendTarget
            if sendTarget != nil { $0.wasReset = false }
        }
        eventContinuation.yield(.attached(sendTarget))
    }

    /// Updates the negotiated SCTP max-message-size cap, ordered with the writes it gates.
    func set(maxMessageSize: UInt64) {
        eventContinuation.yield(.configured(maxMessageSize: maxMessageSize))
    }

    /// Bytes the channel has drained since its last report. Called by the delegate hook below, and
    /// directly by tests.
    func reportDrained(_ byteCount: UInt64) {
        eventContinuation.yield(.drained(byteCount))
    }

    /// Submits work. Under ``SendOverflow/park`` the continuation resumes when the input's last write
    /// reaches `sendData`; under ``SendOverflow/dropOldest`` an evicted group's waiter is resolved
    /// rather than stranded.
    /// - Warning: Cancelling the submitting task does **not** withdraw a queued write; it stays
    ///   queued until the channel takes it or ``reset(throwing:)`` fails it.
    func submit(_ input: Stage.Input, continuation: CheckedContinuation<Void, any Error>? = nil) {
        eventContinuation.yield(.submitted(input, continuation))
    }

    /// Submits work and suspends until its last write reaches the channel (or it is dropped,
    /// failed, or rejected). The one place the resume-exactly-once contract is wrapped: callers
    /// that need an await use this rather than re-deriving the wrapping — and the awaited `self`
    /// keeps the drain alive for the write's whole lifetime, which the raw entry point requires of
    /// its callers.
    func send(_ input: Stage.Input) async throws {
        try await withCheckedThrowingContinuation { continuation in
            submit(input, continuation: continuation)
        }
    }

    /// Submits an out-of-band request, ordered behind work already submitted.
    func submit(command: Stage.Command) {
        eventContinuation.yield(.commanded(command))
    }

    /// Closes the channel and fails everything queued for it. The failure routes through the event
    /// stream so it is ordered after submissions already in flight from concurrent callers, and no
    /// continuation leaks across a disconnect.
    func reset(throwing error: Error? = nil) {
        let previous = _state.mutate { state -> DrainSendChannel? in
            let previous = state.sendTarget
            state.sendTarget = nil
            state.wasReset = true
            return previous
        }
        if let channel = previous as? LKRTCDataChannel, channel.delegate === self {
            channel.delegate = nil
        }
        parkChannelRelease(previous, closing: true)

        eventContinuation.yield(.fail(error))
    }

    func info() -> Livekit_DataChannelInfo? {
        (_state.sendTarget as? LKRTCDataChannel)?.toLKInfoType()
    }

    // MARK: - Event loop

    private func process(_ event: Event, state: inout LoopState) {
        switch event {
        case let .submitted(input, continuation):
            enqueue(input, continuation: continuation, state: &state)
        case let .commanded(command):
            // Replays append synchronously, inside this event: routing them back through the
            // stream would let a concurrent reset()'s .fail land between two replays, re-queueing
            // writes stamped with pre-reset sequences into the next session.
            state.stage.handle(command) { write in
                state.queue.append(write)
            }
        case let .drained(byteCount):
            if !state.meter.didDrain(byteCount) {
                log("Unexpected buffer size detected on '\(label)'", .error)
            }
            state.stage.didDrain(byteCount)
        case let .attached(target):
            if state.sendTarget !== target { parkChannelRelease(state.sendTarget) }
            state.sendTarget = target
            state.meter.reset()
            // Anything queued belonged to the channel that just went away. A dropped write on a
            // drop-oldest channel is the contract rather than a failure, so its waiter is resolved
            // — the same outcome client-sdk-js gives a dropped lossy packet.
            if case .dropOldest = overflow { state.queue.settleAll(.success(())) }
        case let .configured(maxMessageSize):
            state.maxMessageSize = maxMessageSize
        case .wakeup:
            break
        case let .fail(error):
            state.queue.settleAll(.failure(error ?? LiveKitError(.cancelled, message: "Data channel reset")))
            state.stage.reset()
            parkChannelRelease(state.sendTarget)
            state.sendTarget = nil
            // The buffer died with the channel: without this, an app that backed off on
            // `isLow == false` would wait forever for the recovering transition on a
            // permanent disconnect.
            state.meter.reset()
        }

        dispatch(state: &state)
        publishStatusIfChanged(state: &state)
    }

    private func publishStatusIfChanged(state: inout LoopState) {
        let isLow = state.meter.hasHeadroom
        guard isLow != state.wasLow else { return }
        state.wasLow = isLow
        onBufferStatusChange(isLow)
    }

    private func enqueue(
        _ input: Stage.Input,
        continuation: CheckedContinuation<Void, any Error>?,
        state: inout LoopState,
    ) {
        state.scratch.removeAll(keepingCapacity: true)
        do {
            try state.stage.prepare(input, into: &state.scratch)
            try makeWrites(
                from: state.scratch,
                into: &state.writes,
                continuation: continuation,
                maxMessageSize: state.maxMessageSize,
            )
        } catch {
            continuation?.resume(throwing: error)
            return
        }
        guard !state.writes.isEmpty else {
            continuation?.resume()
            return
        }

        switch overflow {
        case .park:
            // Reused scratch: the reliable hot path allocates no group array.
            state.queue.append(state.writes)
        case .dropOldest:
            for evicted in state.queue.evict(replacingWith: state.writes) {
                // Dropping under backpressure is what this policy promises, so a waiting submitter
                // is resolved, not failed — the same outcome client-sdk-js's 'drop' behaviour gives
                // (returns normally, counts the drop). Which packet dies differs by design: js
                // drops the incoming payload; this drain keeps the freshest, which suits the
                // supersede-style data (cursor, presence, state) the lossy channel carries.
                state.dropped += 1
                if state.dropped % Self.dropLogInterval == 0 {
                    log("Dropped \(state.dropped) writes on '\(label)' under backpressure", .warning)
                }
                evicted.settle(with: .success(()))
            }
        }
    }

    /// Feeds the channel while the meter has headroom. `send` blocks on WebRTC's network thread
    /// (the ObjC `sendData` is a proxied `BlockingCall`), so a stalled network thread pins this
    /// loop's cooperative-pool thread for the stall's duration — accepted because the same call was
    /// already made off-queue by the predecessor loop, the stall is bounded by WebRTC's own
    /// signaling timeouts, and a dedicated executor for the drains is the eventual fix if pool
    /// starvation is ever observed.
    private func dispatch(state: inout LoopState) {
        while state.meter.hasHeadroom {
            // Readiness before promotion: while the channel is still opening, a queued group must
            // stay in the evictable `pending` slot so a newer group can still replace it —
            // promoted into `inFlight`, eviction can't reach it and it ships stale once the
            // channel opens. (No-op for `.park`, which never uses `pending`.)
            guard let channel = state.sendTarget, channel.isOpen else {
                // The channel can go away between the readiness report and here — e.g. mid
                // fast-reconnect. Leave the write at the head; the next `.wakeup` ships it, and
                // permanent teardown fails it via `.fail`.
                return
            }
            state.queue.promoteIfIdle()
            guard let write = state.queue.next else { return }
            state.meter.willSend(write.byteCount)

            guard channel.send(write.payload) else {
                // Never reached the transport, so they are not outstanding after all.
                state.meter.didDrain(UInt64(write.byteCount))
                let failure = LiveKitError(.invalidState, message: "sendData failed")
                // Removed *before* it is settled, so no later cleanup can reach this write's
                // continuation a second time — dropFailedWrite settles only what remains.
                state.queue.advance()
                write.settle(with: .failure(failure))
                dropFailedWrite(state: &state, throwing: failure)
                return
            }
            state.queue.advance()
            write.settle(with: .success(()))
            state.stage.didDispatch(write)
        }
    }

    /// Drops what a rejected `sendData` invalidated, settling every discarded write.
    ///
    /// Under ``SendOverflow/park`` only the rejected write goes; the rest of the queue belongs to
    /// other submitters and still has somewhere to go. Under ``SendOverflow/dropOldest`` the rest
    /// of the group goes with it, since half a frame on the wire is worse than none — and a group's
    /// continuation rides its *last* write, so the discarded remainder is failed rather than
    /// dropped, or a caller awaiting a multi-write group would hang forever.
    private func dropFailedWrite(state: inout LoopState, throwing failure: LiveKitError) {
        switch overflow {
        case .park:
            break // the failed write was already removed; the rest belongs to other submitters
        case .dropOldest:
            log("Channel '\(label)' rejected a write; dropping the rest of the group", .debug)
            for discarded in state.queue.dropInFlight() {
                discarded.settle(with: .failure(failure))
            }
        }
    }

    // MARK: - RTCDataChannelDelegate

    //
    // Declared on the class rather than in an extension: extensions of generic classes cannot
    // contain `@objc` members, and this is an `@objc` protocol.

    /// Whether a delegate callback comes from the channel this drain currently owns. A replaced
    /// channel keeps delivering callbacks from WebRTC's threads until its detach lands; acting on
    /// those corrupts the successor's state (a stale drain report against a fresh meter, a stale
    /// close re-arming an open gate).
    private func isCurrent(_ dataChannel: LKRTCDataChannel) -> Bool {
        _state.read { $0.sendTarget === dataChannel }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        guard isCurrent(dataChannel) else { return }
        reportDrained(amount)
    }

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        guard isCurrent(dataChannel) else { return }
        if dataChannel.readyState == .closed, !_state.wasReset {
            // libwebrtc closes the channel on its own when an SCTP send violates the negotiated
            // max-message-size (among other conditions). `sendData` still returns true in that
            // case, so this is the only signal. The guard in `enqueue` is the primary defense;
            // this log surfaces anything that gets past it.
            log("data channel '\(dataChannel.label)' closed unexpectedly", .error)
        }

        if dataChannel.readyState == .open {
            eventContinuation.yield(.wakeup)
        }
        onStateChange(dataChannel)
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard isCurrent(dataChannel) else { return }
        onMessage(buffer.data)
    }
}

// swiftlint:enable file_length
