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

// MARK: - Channel seam

/// The slice of a data channel that ``DataChannelDrain`` sends through — a seam so the queue and its
/// overflow policy stay unit-testable (`LKRTCDataChannel` cannot be constructed without a live peer
/// connection).
protocol DrainSendChannel: AnyObject, Sendable {
    var isOpen: Bool { get }
    func send(_ buffer: LKRTCDataBuffer) -> Bool
}

extension LKRTCDataChannel: DrainSendChannel {
    var isOpen: Bool { readyState == .open }

    func send(_ buffer: LKRTCDataBuffer) -> Bool {
        sendData(buffer)
    }
}

// MARK: - Write phases

/// Serialized bytes and the sequence stamped on them: what a ``SendStage`` produces, before the
/// drain size-checks them and wraps them for the channel.
struct PreparedBytes {
    var bytes: Data
    var sequence: UInt32

    init(bytes: Data, sequence: UInt32 = 0) {
        self.bytes = bytes
        self.sequence = sequence
    }
}

/// A write that has been serialized, stamped and size-checked, and so is the only thing
/// `channel.sendData(...)` accepts. Carries the submitter's continuation if it has one — only the
/// last write of a group does, and a replayed write never does.
struct ReadyWrite {
    let data: LKRTCDataBuffer
    let sequence: UInt32
    let continuation: CheckedContinuation<Void, any Error>?

    var byteCount: Int { data.data.count }
}

/// A dispatched write kept for SCTP-level replay on resume.
///
/// Has no continuation *field*, which is the point: replay hands the same bytes over again, so a
/// retained write that could still resume a submitter would resume it more than once.
struct RetainedWrite {
    let data: LKRTCDataBuffer
    let sequence: UInt32

    init(_ write: ReadyWrite) {
        data = write.data
        sequence = write.sequence
    }

    /// Re-enters the queue with no waiter to resume.
    var replayed: ReadyWrite {
        ReadyWrite(data: data, sequence: sequence, continuation: nil)
    }
}

// MARK: - Stage

/// Per-channel send policy: what a submitted input turns into, what to remember about writes that
/// go out, and what out-of-band requests the channel accepts.
///
/// Driven by ``DataChannelDrain`` from its single event-loop consumer, in FIFO order, so state kept
/// here needs no synchronization of its own.
protocol SendStage: Sendable {
    /// What submitters hand over. One input becomes one group of writes, dispatched in order and
    /// never interleaved with another group's.
    associatedtype Input: Sendable

    /// Out-of-band requests, ordered with the writes. `Never` when the channel has none.
    associatedtype Command: Sendable = Never

    /// Serializes `input` into the bytes to send, appending them in order.
    ///
    /// Runs at submit time, inside the drain's single consumer, so a sequence stamped here matches
    /// the FIFO order in which writes reach `sendData` — which the SFU's per-publisher dedup gate
    /// requires. Throwing rejects the whole input; the drain fails its continuation.
    mutating func prepare(_ input: Input, into prepared: inout [PreparedBytes]) throws

    /// A write reached `sendData`.
    mutating func didDispatch(_ write: ReadyWrite)

    /// The channel reported draining `byteCount` bytes.
    mutating func didDrain(_ byteCount: UInt64)

    /// Handles an out-of-band request. `replay` re-queues a retained write ahead of new work.
    mutating func handle(_ command: Command, replay: (ReadyWrite) -> Void)

    /// The channel is gone: forget anything tied to it.
    mutating func reset()
}

extension SendStage {
    mutating func didDispatch(_: ReadyWrite) {}
    mutating func didDrain(_: UInt64) {}
    mutating func handle(_: Command, replay _: (ReadyWrite) -> Void) {}
    mutating func reset() {}
}

// MARK: - Queue

/// What happens when writes arrive faster than the channel drains.
enum SendOverflow: Sendable {
    /// Queue without bound; every submitter waits its turn, in order.
    case park
    /// Hold only the freshest group, evicting the one waiting before it. A channel swap discards
    /// what was queued for the previous channel: it was already stale.
    ///
    /// - Note: Capacity is fixed at one group, as in rust-sdks' `DataChannelSender`. Add a depth
    ///   when something wants more than "freshest wins".
    case dropOldest
}

/// A drain's outbound queue. Under ``SendOverflow/park`` `inFlight` is the whole queue; under
/// ``SendOverflow/dropOldest`` it is the group being handed over, and `pending` is the one waiting.
struct WriteQueue {
    /// Writes the channel takes next, in order.
    var inFlight: Deque<ReadyWrite> = []
    /// ``SendOverflow/dropOldest`` only: the freshest group, waiting for `inFlight` to empty.
    var pending: [ReadyWrite]?
}
