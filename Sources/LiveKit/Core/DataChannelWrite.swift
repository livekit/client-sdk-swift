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
    func send(_ payload: Data) -> Bool
}

extension LKRTCDataChannel: DrainSendChannel {
    var isOpen: Bool { readyState == .open }

    func send(_ payload: Data) -> Bool {
        // The buffer is built here, at send time, not when the write was queued: the init memcpys
        // the payload into a CopyOnWriteBuffer, and on a drop-oldest channel a queued write is
        // routinely evicted before it ever gets this far — evicted bytes should cost nothing.
        // (Constructed directly rather than via `RTC.createDataBuffer`: that helper's
        // `DispatchQueue.liveKitWebRTC.sync` hop serializes factory access, which a plain
        // byte-container init does not need — see the data-channel exception in AGENTS.md.)
        sendData(LKRTCDataBuffer(data: payload, isBinary: true))
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

/// The one-shot handle on a submitter's continuation.
///
/// Settlement is idempotent — the first outcome wins and any later attempt is a no-op — so no code
/// path can trap on a double resume, and a token released without ever being settled fails its
/// submitter from `deinit` rather than stranding it forever. Copies of a write share the one token,
/// which is what makes both properties hold across evict/drop/teardown paths.
///
/// `@unchecked Sendable`: created, settled and released only inside the drain's single-consumer
/// event loop (it rides `ReadyWrite`, which never leaves the loop), so the mutable state needs no
/// synchronization of its own.
final class SendToken: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func settle(with result: Result<Void, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    deinit {
        continuation?.resume(throwing: LiveKitError(.cancelled, message: "Write dropped without settlement"))
    }
}

/// A write that has been serialized, stamped and size-checked, and so is ready for the channel.
/// Carries its submitter's token if it has one — only the last write of a group does, and a
/// replayed write never does.
struct ReadyWrite {
    let payload: Data
    let sequence: UInt32
    let token: SendToken?

    init(payload: Data, sequence: UInt32, token: SendToken? = nil) {
        self.payload = payload
        self.sequence = sequence
        self.token = token
    }

    var byteCount: Int { payload.count }

    /// Resolves or fails the submitter, if one is waiting. Safe on every path: see ``SendToken``.
    func settle(with result: Result<Void, any Error>) {
        token?.settle(with: result)
    }
}

/// A dispatched write kept for SCTP-level replay on resume.
///
/// Has no token *field*, which is the point: replay hands the same bytes over again, so a retained
/// write that could still resume a submitter would resume it more than once.
struct RetainedWrite {
    let payload: Data
    let sequence: UInt32

    init(_ write: ReadyWrite) {
        payload = write.payload
        sequence = write.sequence
    }

    /// Re-enters the queue with no waiter to resume.
    var replayed: ReadyWrite {
        ReadyWrite(payload: payload, sequence: sequence)
    }
}

/// Turns one group's prepared bytes into writes, rejecting any that exceeds the negotiated SCTP
/// max-message-size (`0` disables the check). Appends into `group`, a caller-reused scratch, so the
/// per-submit hot path allocates nothing.
///
/// Oversized writes are rejected here because sending more than the negotiated size makes libwebrtc
/// tear the channel down — `sendData` reports success and the channel then closes, breaking every
/// later send.
///
/// Only the last write carries `continuation`, so a submitter resumes once its whole group has been
/// handed over.
func makeWrites(
    from prepared: [PreparedBytes],
    into group: inout [ReadyWrite],
    continuation: CheckedContinuation<Void, any Error>?,
    maxMessageSize: UInt64,
) throws {
    group.removeAll(keepingCapacity: true)
    group.reserveCapacity(prepared.count)

    for (index, bytes) in prepared.enumerated() {
        if maxMessageSize != 0, UInt64(bytes.bytes.count) > maxMessageSize {
            throw LiveKitError(
                .invalidParameter,
                message: "data packet size (\(bytes.bytes.count) bytes) exceeds the negotiated max-message-size (\(maxMessageSize) bytes)",
            )
        }
        group.append(ReadyWrite(
            payload: bytes.bytes,
            sequence: bytes.sequence,
            token: index == prepared.count - 1 ? continuation.map(SendToken.init) : nil,
        ))
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

    var next: ReadyWrite? { inFlight.first }

    mutating func append(_ write: ReadyWrite) {
        inFlight.append(write)
    }

    mutating func append(_ group: [ReadyWrite]) {
        for write in group {
            inFlight.append(write)
        }
    }

    /// Promotes the waiting group once the group being handed over is done, so a group's writes are
    /// never interleaved with another's.
    mutating func promoteIfIdle() {
        guard inFlight.isEmpty, let group = pending else { return }
        pending = nil
        append(group)
    }

    /// Replaces the waiting group, handing back the one it displaced so the caller can settle any
    /// continuations rather than strand them.
    mutating func evict(replacingWith group: [ReadyWrite]) -> [ReadyWrite] {
        let displaced = pending ?? []
        pending = group
        return displaced
    }

    mutating func advance() {
        if !inFlight.isEmpty { inFlight.removeFirst() }
    }

    /// Empties the queue, handing back every write so the caller can settle their continuations.
    mutating func removeAll() -> [ReadyWrite] {
        var removed = pending ?? []
        pending = nil
        while !inFlight.isEmpty {
            removed.append(inFlight.removeFirst())
        }
        return removed
    }

    /// Empties the queue, settling every waiting submitter with `outcome`.
    mutating func settleAll(_ outcome: Result<Void, any Error>) {
        for write in removeAll() {
            write.settle(with: outcome)
        }
    }

    /// Drops the group being handed over, keeping whatever is waiting behind it, and hands the
    /// discarded writes back so the caller can settle their continuations.
    mutating func dropInFlight() -> [ReadyWrite] {
        var discarded: [ReadyWrite] = []
        while !inFlight.isEmpty {
            discarded.append(inFlight.removeFirst())
        }
        return discarded
    }
}
