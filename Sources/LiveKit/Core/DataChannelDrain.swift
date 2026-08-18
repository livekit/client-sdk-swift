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
/// not own it forwards to its creator: inbound messages via `onMessage`, and readiness via
/// `onStateChange` (``DataChannelPair`` needs it for the pair-level open latch). This mirrors
/// `DataChannelManager` in client-sdk-android, which is its channel's `DataChannel.Observer` and
/// takes a listener to forward messages to.
///
/// ## Queue
/// See ``WriteQueue`` and ``SendOverflow``. Either way a group is dispatched whole, so a partial
/// group is never left on the wire.
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
        var channel: LKRTCDataChannel?
        /// The same object as `channel` in production; a fake in tests.
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
        /// Reused across `prepare` calls. Lives here rather than on the drain so that only the
        /// loop's single observer can reach it.
        var scratch: [PreparedBytes] = []
    }

    private enum Event {
        /// Work to prepare and queue.
        case submitted(Stage.Input, CheckedContinuation<Void, any Error>?)
        /// An already-prepared write coming back from the stage's replay path, which must not be
        /// re-prepared: its bytes are stamped with a now-stale sequence on purpose.
        case replayed(ReadyWrite)
        case commanded(Stage.Command)
        case drained(UInt64)
        case retune(UInt64)
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

    private let overflow: SendOverflow
    private let onMessage: @Sendable (Data) -> Void
    private let onStateChange: @Sendable (LKRTCDataChannel) -> Void

    private let _state = StateSync(State())
    private let eventContinuation: AsyncStream<Event>.Continuation
    /// Assigned once in `init`, before the drain escapes — it cannot be a `let` because
    /// `subscribe` needs a fully initialized `self`. Never read or reassigned afterwards; it is
    /// held so that its `deinit` cancels the loop.
    private var eventLoopTask: AnyTaskCancellable?

    init(
        label _: String,
        lowWaterMark: UInt64,
        overflow: SendOverflow,
        stage: Stage,
        maxMessageSize: UInt64 = 0,
        onMessage: @escaping @Sendable (Data) -> Void = { _ in },
        onStateChange: @escaping @Sendable (LKRTCDataChannel) -> Void = { _ in },
    ) {
        self.overflow = overflow
        self.onMessage = onMessage
        self.onStateChange = onStateChange

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

    /// Attaches the channel this drain sends on and takes over its delegate slot.
    ///
    /// Under ``SendOverflow/park`` anything already queued survives the swap and ships on the new
    /// channel, which is what makes a fast reconnect lossless; under ``SendOverflow/dropOldest`` it is
    /// discarded as stale.
    func setChannel(_ channel: LKRTCDataChannel?) {
        _state.mutate {
            $0.channel = channel
            if channel != nil { $0.wasReset = false }
        }
        channel?.delegate = self
        attach(sendTarget: channel)
    }

    /// Attaches what writes go to. Split from ``setChannel(_:)`` so tests can drive the queue
    /// without a real channel; production always passes the channel itself.
    func attach(sendTarget: DrainSendChannel?) {
        _state.mutate { $0.sendTarget = sendTarget }
        eventContinuation.yield(.attached)
    }

    /// Bytes the channel has drained since its last report. Called by the delegate hook below, and
    /// directly by tests.
    func reportDrained(_ byteCount: UInt64) {
        eventContinuation.yield(.drained(byteCount))
    }

    /// Retunes the low-water gate, ordered with the writes it governs.
    func setLowWaterMark(_ mark: UInt64) {
        eventContinuation.yield(.retune(mark))
    }

    /// Submits work. Under ``SendOverflow/park`` the continuation resumes when the input's last write
    /// reaches `sendData`; under ``SendOverflow/dropOldest`` there is normally none, and an evicted
    /// group's waiter is failed rather than stranded.
    ///
    /// - Warning: Cancelling the submitting task does **not** withdraw a write that is already
    ///   queued. It stays queued until the channel takes it or ``reset(throwing:)`` fails it. This
    ///   is a pre-existing limitation of the continuation-based entry point, carried over
    ///   deliberately.
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
        let channel = _state.mutate {
            let previous = $0.channel
            $0.channel = nil
            $0.sendTarget = nil
            $0.wasReset = true
            return previous
        }
        channel?.close()

        eventContinuation.yield(.fail(error))
    }

    func info() -> Livekit_DataChannelInfo? {
        _state.channel?.toLKInfoType()
    }

    // MARK: - Event loop

    private func process(_ event: Event, state: inout LoopState) {
        switch event {
        case let .submitted(input, continuation):
            enqueue(input, continuation: continuation, state: &state)
        case let .replayed(write):
            state.queue.append([write])
        case let .commanded(command):
            state.stage.handle(command) { [weak self] write in
                // Through the stream, so replayed writes queue in the order the stage emits them
                // and behind work already submitted.
                self?.eventContinuation.yield(.replayed(write))
            }
        case let .drained(byteCount):
            if !state.meter.didDrain(byteCount) {
                log("Unexpected buffer size detected", .error)
            }
            state.stage.didDrain(byteCount)
        case let .retune(mark):
            state.meter.setLowWaterMark(mark)
        case .attached:
            state.meter.reset()
            // Anything queued belonged to the channel that just went away. A dropped write on a
            // drop-oldest channel is the contract rather than a failure, so its waiter is resolved
            // — the same outcome client-sdk-js gives a dropped lossy packet.
            if case .dropOldest = overflow { state.queue.settleAll(.success(())) }
        case .wakeup:
            break
        case let .fail(error):
            state.queue.settleAll(.failure(error ?? LiveKitError(.cancelled, message: "Data channel reset")))
            state.stage.reset()
            return
        }

        dispatch(state: &state)
    }

    private func enqueue(
        _ input: Stage.Input,
        continuation: CheckedContinuation<Void, any Error>?,
        state: inout LoopState,
    ) {
        state.scratch.removeAll(keepingCapacity: true)
        do {
            try state.stage.prepare(input, into: &state.scratch)
        } catch {
            continuation?.resume(throwing: error)
            return
        }

        let limit = _state.maxMessageSize
        var group: [ReadyWrite] = []
        group.reserveCapacity(state.scratch.count)
        for (index, prepared) in state.scratch.enumerated() {
            // Encoded size is what goes on the wire; sending more than the negotiated
            // max-message-size makes libwebrtc tear the channel down (`sendData` returns success,
            // then it closes), breaking every later send. Reject here instead.
            if limit != 0, UInt64(prepared.bytes.count) > limit {
                continuation?.resume(throwing: LiveKitError(
                    .invalidParameter,
                    message: "data packet size (\(prepared.bytes.count) bytes) exceeds the negotiated max-message-size (\(limit) bytes)",
                ))
                return
            }
            // Only the last write of a group carries the continuation, so it resumes once the
            // whole group has been handed over.
            let isLast = index == state.scratch.count - 1
            group.append(ReadyWrite(
                // Constructed directly rather than via `RTC.createDataBuffer`, whose
                // `DispatchQueue.liveKitWebRTC.sync` hop would block a cooperative-pool thread once
                // per write. The buffer is a plain container; that helper's queue exists to
                // serialize factory access, which this does not need.
                data: LKRTCDataBuffer(data: prepared.bytes, isBinary: true),
                sequence: prepared.sequence,
                continuation: isLast ? continuation : nil,
            ))
        }
        guard !group.isEmpty else {
            continuation?.resume()
            return
        }

        switch overflow {
        case .park:
            for write in group {
                state.queue.inFlight.append(write)
            }
        case .dropOldest:
            for evicted in state.queue.evict(replacingWith: group) {
                // Dropping under backpressure is what this policy promises, so a waiting submitter
                // is resolved, not failed — matching `sendLossyBytes`' 'drop' behaviour in
                // client-sdk-js. Counted so sustained loss is visible.
                state.dropped += 1
                if state.dropped % Self.dropLogInterval == 0 {
                    log("Dropped \(state.dropped) writes under backpressure", .warning)
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
                // permanent teardown fails it via `.teardown`.
                return
            }
            state.meter.willSend(write.byteCount)

            guard channel.send(write.data) else {
                // Never reached the transport, so they are not outstanding after all.
                state.meter.didDrain(UInt64(write.byteCount))
                write.continuation?.resume(
                    throwing: LiveKitError(.invalidState, message: "sendData failed"),
                )
                dropFailedWrite(state: &state)
                return
            }
            state.queue.advance()
            write.continuation?.resume()
            state.stage.didDispatch(write)
        }
    }

    /// Drops what a rejected `sendData` invalidated, resuming nothing — the write's continuation
    /// has already been failed.
    ///
    /// Under ``SendOverflow/park`` only the rejected write goes; the rest of the queue belongs to other
    /// submitters and still has somewhere to go. (Park stages produce one write per input today, so
    /// there is no partial group to consider; a multi-write park stage would need to revisit this.)
    /// Under ``SendOverflow/dropOldest`` the rest of the group goes with it, since half a frame on the
    /// wire is worse than none.
    private func dropFailedWrite(state: inout LoopState) {
        switch overflow {
        case .park:
            state.queue.advance()
        case .dropOldest:
            log("Channel rejected a write; dropping the rest of the group", .debug)
            state.queue.dropInFlight()
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

    func dataChannel(_: LKRTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        reportDrained(amount)
    }

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
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

    func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        onMessage(buffer.data)
    }
}
