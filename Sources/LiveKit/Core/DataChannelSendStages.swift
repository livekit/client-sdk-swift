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

/// Bounded store of dispatched reliable writes, kept for SCTP-level replay after a resume.
///
/// Trimmed as the channel drains, down to `minAmount` above the reported bound, so what is retained
/// stays roughly the set the peer may not have received.
struct RetryBuffer {
    private var queue: Deque<RetainedWrite> = []
    private var currentAmount: UInt64 = 0
    private let minAmount: UInt64

    init(minAmount: UInt64) {
        self.minAmount = minAmount
    }

    func peek() -> RetainedWrite? { queue.first }

    mutating func enqueue(_ write: ReadyWrite) {
        queue.append(RetainedWrite(write))
        currentAmount += UInt64(write.byteCount)
    }

    @discardableResult
    mutating func dequeue() -> RetainedWrite? {
        guard !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        currentAmount -= UInt64(first.payload.count)
        return first
    }

    mutating func removeAll() {
        queue = []
        currentAmount = 0
    }

    mutating func trim(toAmount: UInt64) {
        while currentAmount > toAmount + minAmount {
            dequeue()
        }
    }
}

// MARK: - Lossy

/// The lossy channel: serialize and go. Nothing is sequenced and nothing is replayed.
struct LossyStage: SendStage {
    typealias Input = Livekit_DataPacket

    mutating func prepare(_ input: Livekit_DataPacket, into prepared: inout [PreparedBytes]) throws {
        try prepared.append(PreparedBytes(bytes: input.serializedData()))
    }
}

// MARK: - Reliable

/// The reliable channel: stamps the per-publisher sequence the SFU dedups on, and retains
/// dispatched writes so a resume can replay whatever the peer missed.
struct ReliableStage: SendStage, Loggable {
    typealias Input = Livekit_DataPacket

    enum Command: Sendable {
        /// The SFU asked for everything after `sequence` to be sent again.
        case replay(after: UInt32)
    }

    private var nextSequence: UInt32 = 1
    private var retry: RetryBuffer

    init(retryFloor: UInt64) {
        retry = RetryBuffer(minAmount: retryFloor)
    }

    mutating func prepare(_ input: Livekit_DataPacket, into prepared: inout [PreparedBytes]) throws {
        var bytes = try input.serializedData()
        var sequence = input.sequence

        // Runs in the drain's single consumer, so assigning here means the sequence on the wire
        // matches the order writes reach `sendData`. Assigning at the call site instead would race:
        // two concurrent senders could take N and N+1 but submit in the other order, and the SFU's
        // dedup gate silently drops the lower one.
        if sequence == 0 {
            sequence = nextSequence
            nextSequence += 1
            // Stamped by appending an encoded packet carrying only that field: concatenation is
            // protobuf merge and scalar fields take the last occurrence, so this writes a few bytes
            // rather than re-encoding the whole payload.
            try bytes.append(Livekit_DataPacket.with { $0.sequence = sequence }.serializedData())
        }

        prepared.append(PreparedBytes(bytes: bytes, sequence: sequence))
    }

    mutating func didDispatch(_ write: ReadyWrite) {
        retry.enqueue(write)
    }

    mutating func didDrain(_ byteCount: UInt64) {
        retry.trim(toAmount: byteCount)
    }

    mutating func handle(_ command: Command, replay: (ReadyWrite) -> Void) {
        guard case let .replay(lastSequence) = command else { return }

        if let first = retry.peek(), first.sequence > lastSequence + 1 {
            log("Wrong packet sequence while retrying: \(first.sequence) > \(lastSequence + 1), \(first.sequence - lastSequence - 1) packets missing", .warning)
        }
        while let retained = retry.dequeue() {
            if retained.sequence > lastSequence {
                replay(retained.replayed)
            }
        }
    }

    /// Reached on teardown and full reconnect, never on a resume — a resume is exactly when the
    /// retained writes are needed. The replay set and the sequence share a lifetime: writes stamped
    /// under one counter must not survive into a session whose counter restarted.
    mutating func reset() {
        nextSequence = 1
        retry.removeAll()
    }
}

// MARK: - Data tracks

/// The data-track channel: frames arrive from the Rust engine already serialized and packetized, so
/// there is nothing to encode. One frame is one group, dispatched whole or not at all.
struct DataTrackStage: SendStage {
    typealias Input = [Data]

    mutating func prepare(_ input: [Data], into prepared: inout [PreparedBytes]) throws {
        for packet in input {
            prepared.append(PreparedBytes(bytes: packet))
        }
    }
}
