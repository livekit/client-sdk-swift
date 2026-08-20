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
/// `@unchecked Sendable`. `_state` and `flow` are lock-guarded; `Queue` and `Stage` live in the
/// event loop's subscription state and are touched only by its single observer.
final class DataChannelDrain<Stage: SendStage>: NSObject, LKRTCDataChannelDelegate, @unchecked Sendable, Loggable {
    // MARK: - Public

    /// `0` disables the size guard, which is what channels with no negotiated limit use.
    var maxMessageSize: UInt64 {
        get { _state.maxMessageSize }
        set { _state.mutate { $0.maxMessageSize = newValue } }
    }

    var isOpen: Bool { usableTarget != nil }

    // MARK: - Private

    private struct State {
        /// The channel in production; a fake in tests (see ``attach(sendTarget:)``).
        var sendTarget: DrainSendChannel?
        var maxMessageSize: UInt64 = 0
        /// Set by ``reset(throwing:)`` and cleared when a channel is attached. Distinguishes
        /// SDK-initiated teardown from libwebrtc closing the channel on its own.
        var wasReset: Bool = false
    }

    private struct LoopState {
        var queue = WriteQueue()
        var meter: BufferedAmountMeter
        var stage: Stage
        /// Writes dropped under backpressure, logged periodically rather than per drop.
        var dropped: Int = 0
        /// Last reported buffer status, so only transitions are published.
        var wasLow: Bool = true
        /// Reused across `prepare` calls. Lives here rather than on the drain so that only the
        /// loop's single observer can reach it.
        var scratch: [PreparedBytes] = []
    }

    private enum Event {
        /// Work to prepare and queue.
        case submitted(Stage.Input, CheckedContinuation<Void, any Error>?)
        case commanded(Stage.Command)
        case drained(UInt64)
        /// A channel was attached or swapped: the mirror starts over, and under
        /// ``SendOverflow/dropOldest`` anything queued for the previous channel is dropped.
        case attached
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

        _state.mutate { $0.maxMessageSize = maxMessageSize }

        let initial = LoopState(meter: BufferedAmountMeter(lowWaterMark: lowWaterMark), stage: stage)
        eventLoopTask = events.subscribe(self, state: initial) { drain, event, state in
            drain.process(event, state: &state)
        }
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: - Owner API

    /// Attaches the channel this drain sends on, takes over its delegate slot (detaching the
    /// replaced channel; the identity guard on the hooks is the backstop for callbacks already in
    /// flight), and reports the channel's current state through `onStateChange` — so an owner never
    /// probes `readyState` itself to cover a channel that opened before its delegate landed.
    ///
    /// Under ``SendOverflow/park`` anything already queued survives the swap and ships on the new
    /// channel, which is what makes a fast reconnect lossless; under ``SendOverflow/dropOldest`` it is
    /// discarded as stale.
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
        channel?.delegate = self
        eventContinuation.yield(.attached)
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
        eventContinuation.yield(.attached)
    }

    /// Bytes the channel has drained since its last report. Called by the delegate hook below, and
    /// directly by tests.
    func reportDrained(_ byteCount: UInt64) {
        eventContinuation.yield(.drained(byteCount))
    }

    /// Submits work. Under ``SendOverflow/park`` the continuation resumes when the input's last write
    /// reaches `sendData`; under ``SendOverflow/dropOldest`` there is normally none, and an evicted
    /// group's waiter is failed rather than stranded.
    ///
    /// - Warning: Cancelling the submitting task does **not** withdraw a queued write; it stays
    ///   queued until the channel takes it or ``reset(throwing:)`` fails it. Pre-existing
    ///   limitation of the continuation entry point, carried over deliberately.
    func submit(_ input: Stage.Input, continuation: CheckedContinuation<Void, any Error>? = nil) {
        eventContinuation.yield(.submitted(input, continuation))
    }

    /// Submits an out-of-band request, ordered behind work already submitted.
    func submit(command: Stage.Command) {
        eventContinuation.yield(.commanded(command))
    }

    /// Closes the channel and fails everything queued for it.
    ///
    /// The failure is routed through the event stream so it is ordered after submissions already in
    /// flight from concurrent callers, and no continuation leaks across a disconnect.
    func reset(throwing error: Error? = nil) {
        let previous = _state.mutate { state -> DrainSendChannel? in
            let previous = state.sendTarget
            state.sendTarget = nil
            state.wasReset = true
            return previous
        }
        if let channel = previous as? LKRTCDataChannel {
            if channel.delegate === self { channel.delegate = nil }
            channel.close()
        }

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
        case .attached:
            handleAttached(state: &state)
        case .wakeup:
            break
        case let .fail(error):
            state.queue.settleAll(.failure(error ?? LiveKitError(.cancelled, message: "Data channel reset")))
            state.stage.reset()
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

    private func handleAttached(state: inout LoopState) {
        state.meter.reset()
        // Anything queued belonged to the channel that just went away. A dropped write on a
        // drop-oldest channel is the contract rather than a failure, so its waiter is resolved —
        // the same outcome client-sdk-js gives a dropped lossy packet.
        if case .dropOldest = overflow { state.queue.settleAll(.success(())) }
    }

    private func enqueue(
        _ input: Stage.Input,
        continuation: CheckedContinuation<Void, any Error>?,
        state: inout LoopState,
    ) {
        state.scratch.removeAll(keepingCapacity: true)
        let group: [ReadyWrite]
        do {
            try state.stage.prepare(input, into: &state.scratch)
            group = try makeWrites(
                from: state.scratch,
                continuation: continuation,
                maxMessageSize: _state.maxMessageSize,
            )
        } catch {
            continuation?.resume(throwing: error)
            return
        }
        guard !group.isEmpty else {
            continuation?.resume()
            return
        }

        switch overflow {
        case .park:
            state.queue.append(group)
        case .dropOldest:
            for evicted in state.queue.evict(replacingWith: group) {
                // Dropping under backpressure is what this policy promises, so a waiting submitter
                // is resolved, not failed — matching `sendLossyBytes`' 'drop' behaviour in
                // client-sdk-js. Counted so sustained loss is visible.
                state.dropped += 1
                if state.dropped % Self.dropLogInterval == 0 {
                    log("Dropped \(state.dropped) writes on '\(label)' under backpressure", .warning)
                }
                evicted.continuation?.resume()
            }
        }
    }

    private func dispatch(state: inout LoopState) {
        while state.meter.hasHeadroom {
            state.queue.promoteIfIdle()
            guard let write = state.queue.next else { return }

            guard let channel = usableTarget else {
                // The channel can go away between the readiness report and here — e.g. mid
                // fast-reconnect. Leave the write at the head; the next `.wakeup` ships it, and
                // permanent teardown fails it via `.fail`.
                return
            }
            state.meter.willSend(write.byteCount)

            guard channel.send(write.data) else {
                // Never reached the transport, so they are not outstanding after all.
                state.meter.didDrain(UInt64(write.byteCount))
                let failure = LiveKitError(.invalidState, message: "sendData failed")
                write.continuation?.resume(throwing: failure)
                dropFailedWrite(state: &state, throwing: failure)
                return
            }
            state.queue.advance()
            write.continuation?.resume()
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
            state.queue.advance()
        case .dropOldest:
            log("Channel '\(label)' rejected a write; dropping the rest of the group", .debug)
            for discarded in state.queue.dropInFlight() {
                discarded.continuation?.resume(throwing: failure)
            }
        }
    }

    // MARK: - Channel

    private var usableTarget: DrainSendChannel? {
        _state.read { state in
            guard let target = state.sendTarget, target.isOpen else { return nil }
            return target
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
