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
/// `inFlight` holds writes the channel will take next. Under ``Overflow/park`` it is the whole
/// queue and grows without bound — every submitter waits its turn. Under ``Overflow/dropOldest``
/// only one group is held beyond the one being dispatched, and a newer group evicts it whole, so a
/// partial group is never left on the wire.
///
/// ## Concurrency
/// `@unchecked Sendable`. `_state` and `flow` are lock-guarded; `Queue` and `Stage` live in the
/// event loop's subscription state and are touched only by its single observer.
final class DataChannelDrain<Stage: SendStage>: NSObject, LKRTCDataChannelDelegate, @unchecked Sendable, Loggable {
    /// What happens when writes arrive faster than the channel drains.
    enum Overflow: Sendable {
        /// Queue without bound; every submitter waits its turn, in order.
        case park
        /// Hold only the freshest group, evicting the one waiting before it. A channel swap
        /// discards what was queued for the previous channel: it was already stale.
        ///
        /// - Note: Capacity is fixed at one group, as in rust-sdks' `DataChannelSender`. Add a
        ///   depth when something wants more than "freshest wins".
        case dropOldest
    }

    // MARK: - Public

    let label: String

    /// Outbound flow control: the buffered-amount mirror and the low-water gate.
    let flow: BufferedDataChannel

    /// `0` disables the size guard, which is what channels with no negotiated limit use.
    var maxMessageSize: UInt64 {
        get { _state.maxMessageSize }
        set { _state.mutate { $0.maxMessageSize = newValue } }
    }

    var isOpen: Bool { usableChannel != nil }

    // MARK: - Private

    private struct State {
        var channel: LKRTCDataChannel?
        var maxMessageSize: UInt64 = 0
        /// Set by ``reset(throwing:)`` and cleared when a channel is attached. Distinguishes
        /// SDK-initiated teardown from libwebrtc closing the channel on its own.
        var wasReset: Bool = false
    }

    private struct Queue {
        /// Writes the channel takes next, in order.
        var inFlight: Deque<ReadyWrite> = []
        /// ``Overflow/dropOldest`` only: the freshest group, waiting for `inFlight` to empty.
        var pending: [ReadyWrite]?
    }

    private struct LoopState {
        var queue = Queue()
        var stage: Stage
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
        case wakeup
        /// Discards queued work for a channel that is going away. `failing` is `false` when the
        /// channel is merely being swapped under ``Overflow/dropOldest``, where the queue holds
        /// stale groups and no continuations.
        case discard(error: Error?, failing: Bool)
    }

    private let overflow: Overflow
    private let onMessage: @Sendable (Data) -> Void
    private let onStateChange: @Sendable (LKRTCDataChannel) -> Void

    private let _state = StateSync(State())
    private let eventContinuation: AsyncStream<Event>.Continuation
    private var eventLoopTask: AnyTaskCancellable?

    init(
        label: String,
        lowWaterMark: UInt64,
        overflow: Overflow,
        stage: Stage,
        maxMessageSize: UInt64 = 0,
        onMessage: @escaping @Sendable (Data) -> Void = { _ in },
        onStateChange: @escaping @Sendable (LKRTCDataChannel) -> Void = { _ in },
    ) {
        self.label = label
        self.overflow = overflow
        self.onMessage = onMessage
        self.onStateChange = onStateChange
        flow = BufferedDataChannel(label: label, lowWaterMark: lowWaterMark)

        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        eventContinuation = continuation

        super.init()

        _state.mutate { $0.maxMessageSize = maxMessageSize }

        eventLoopTask = events.subscribe(self, state: LoopState(stage: stage)) { drain, event, state in
            drain.process(event, state: &state)
        }
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: - Owner API

    /// Attaches the channel this drain sends on and takes over its delegate slot.
    ///
    /// Under ``Overflow/park`` anything already queued survives the swap and ships on the new
    /// channel, which is what makes a fast reconnect lossless; under ``Overflow/dropOldest`` it is
    /// discarded as stale.
    func setChannel(_ channel: LKRTCDataChannel?) {
        _state.mutate {
            $0.channel = channel
            if channel != nil { $0.wasReset = false }
        }
        channel?.delegate = self

        flow.reset()
        if case .dropOldest = overflow {
            eventContinuation.yield(.discard(error: nil, failing: false))
        }

        reportReadiness()
        if channel?.readyState == .open {
            eventContinuation.yield(.wakeup)
        }
    }

    /// Submits work. Under ``Overflow/park`` the continuation resumes when the input's last write
    /// reaches `sendData`; under ``Overflow/dropOldest`` there is none, and an evicted group is
    /// dropped silently.
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
            $0.wasReset = true
            return previous
        }
        channel?.close()

        flow.reset(throwing: error)
        eventContinuation.yield(.discard(error: error, failing: true))
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
            state.queue.inFlight.append(write)
        case let .commanded(command):
            state.stage.handle(command) { [weak self] write in
                // Through the stream, so replayed writes queue in the order the stage emits them
                // and behind work already submitted.
                self?.eventContinuation.yield(.replayed(write))
            }
        case let .drained(byteCount):
            state.stage.didDrain(byteCount)
        case .wakeup:
            break
        case let .discard(error, failing):
            if failing {
                let failure = error ?? LiveKitError(.cancelled, message: "Data channel reset")
                while !state.queue.inFlight.isEmpty {
                    state.queue.inFlight.removeFirst().continuation?.resume(throwing: failure)
                }
                for write in state.queue.pending ?? [] {
                    write.continuation?.resume(throwing: failure)
                }
                state.stage.reset()
            } else {
                while !state.queue.inFlight.isEmpty {
                    state.queue.inFlight.removeFirst()
                }
            }
            state.queue.pending = nil
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
                data: RTC.createDataBuffer(data: prepared.bytes),
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
            if let evicted = state.queue.pending {
                log("Evicted queued group (\(evicted.count) writes) in favor of a newer one", .debug)
            }
            state.queue.pending = group
        }
    }

    private func dispatch(state: inout LoopState) {
        while flow.hasHeadroom {
            if state.queue.inFlight.isEmpty {
                guard let next = state.queue.pending else { return }
                state.queue.pending = nil
                for write in next {
                    state.queue.inFlight.append(write)
                }
            }
            guard let write = state.queue.inFlight.first else { return }

            guard let channel = usableChannel else {
                // The channel can go away between the readiness report and here — e.g. mid
                // fast-reconnect. Leave the write at the head; the next `.wakeup` ships it, and
                // permanent teardown fails it via `.teardown`.
                return
            }
            guard channel.sendData(write.data) else {
                write.continuation?.resume(
                    throwing: LiveKitError(.invalidState, message: "sendData failed"),
                )
                dropFailedWrite(state: &state)
                return
            }
            state.queue.inFlight.removeFirst()
            // Bytes are in WebRTC's SCTP queue now; account for them so the gate above closes for
            // subsequent iterations.
            flow.didSend(write.byteCount)
            write.continuation?.resume()
            state.stage.didDispatch(write)
        }
    }

    /// Drops what a rejected `sendData` invalidated, resuming nothing — the write's continuation
    /// has already been failed.
    ///
    /// Under ``Overflow/park`` only the rejected write goes; the rest of the queue belongs to other
    /// submitters and still has somewhere to go. (Park stages produce one write per input today, so
    /// there is no partial group to consider; a multi-write park stage would need to revisit this.)
    /// Under ``Overflow/dropOldest`` the rest of the group goes with it, since half a frame on the
    /// wire is worse than none.
    private func dropFailedWrite(state: inout LoopState) {
        switch overflow {
        case .park:
            if !state.queue.inFlight.isEmpty { state.queue.inFlight.removeFirst() }
        case .dropOldest:
            log("Channel rejected a write; dropping the rest of the group", .debug)
            while !state.queue.inFlight.isEmpty {
                state.queue.inFlight.removeFirst()
            }
        }
    }

    // MARK: - Channel

    private var usableChannel: LKRTCDataChannel? {
        _state.read { state in
            guard let channel = state.channel, channel.readyState == .open else { return nil }
            return channel
        }
    }

    private func reportReadiness() {
        flow.setReady(usableChannel != nil)
    }

    // MARK: - RTCDataChannelDelegate

    //
    // Declared on the class rather than in an extension: extensions of generic classes cannot
    // contain `@objc` members, and this is an `@objc` protocol.

    func dataChannel(_: LKRTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        // The mirror is lock-guarded and only gates sending, so it is updated here rather than in
        // the loop; the stage's own accounting is ordered with the queue via the event.
        flow.didDrain(amount)
        eventContinuation.yield(.drained(amount))
    }

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        if dataChannel.readyState == .closed, !_state.wasReset {
            // libwebrtc closes the channel on its own when an SCTP send violates the negotiated
            // max-message-size (among other conditions). `sendData` still returns true in that
            // case, so this is the only signal. The guard in `enqueue` is the primary defense;
            // this log surfaces anything that gets past it.
            log("data channel '\(dataChannel.label)' closed unexpectedly", .error)
        }

        reportReadiness()
        if dataChannel.readyState == .open {
            eventContinuation.yield(.wakeup)
        }
        onStateChange(dataChannel)
    }

    func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        onMessage(buffer.data)
    }
}
