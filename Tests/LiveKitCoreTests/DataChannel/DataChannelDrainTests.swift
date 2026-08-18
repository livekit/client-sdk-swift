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
@testable import LiveKit
import LiveKitWebRTC
import Testing

/// Stands in for the channel the drain sends through. Reads come from the test's task while writes
/// come from the drain's loop, so the state lives in a `StateSync` — the SDK's own primitive, rather
/// than a lock of the test's own.
private final class FakeSendChannel: DrainSendChannel, Sendable {
    private struct State {
        var isOpen = true
        var acceptsSends = true
        var sent: [Data] = []
        /// What the transport still holds. The drain never reads this — it mirrors what it hands
        /// over — so this models the transport and sources the drained byte counts.
        var outstanding: UInt64 = 0
    }

    private let _state = StateSync(State())

    var isOpen: Bool {
        get { _state.isOpen }
        set { _state.mutate { $0.isOpen = newValue } }
    }

    var acceptsSends: Bool {
        get { _state.acceptsSends }
        set { _state.mutate { $0.acceptsSends = newValue } }
    }

    var sent: [Data] { _state.sent }
    var tags: [UInt8?] { _state.sent.map(\.first) }
    var outstanding: UInt64 { _state.outstanding }

    func send(_ buffer: LKRTCDataBuffer) -> Bool {
        _state.mutate { state in
            guard state.acceptsSends else { return false }
            state.sent.append(buffer.data)
            state.outstanding += UInt64(buffer.data.count)
            return true
        }
    }

    /// Flushes the buffer and returns the drained byte count, as `didChangeBufferedAmount` does.
    func flush() -> UInt64 {
        _state.mutate { state in
            let drained = state.outstanding
            state.outstanding = 0
            return drained
        }
    }
}

/// Pins ``DataChannelDrain``'s queue semantics under ``DataChannelDrain/Overflow/dropOldest``, which
/// is what the data-track channel uses, and which is deliberately aligned (and deliberately not)
/// with the other SDKs:
///
/// - **rust-sdks** (`DataChannelSender`): the same design — drop-oldest with a capacity-one group,
///   whole-group atomicity, writes metered on buffered-amount events with an 8 KiB low-water mark.
///   These tests mirror its invariants.
/// - **client-sdk-js** (`LossyDataChannel` with `bufferFullBehavior: 'wait'`): shares the
///   whole-group atomicity and watermark pacing, but blocks the producer under load instead of
///   dropping — its engine awaits sends, so overload backpressures the producer. Swift's producer is
///   a fire-and-forget FFI callback with no backpressure channel, so freshest-wins eviction is used
///   instead (as in rust-sdks).
@Suite(.tags(.dataChannel, .dataTrack))
struct DataChannelDrainTests {
    private static let mark: UInt64 = 8 * 1024

    private let channel = FakeSendChannel()
    private let drain: DataChannelDrain<DataTrackStage>

    init() {
        drain = DataChannelDrain(
            label: "test",
            lowWaterMark: Self.mark,
            overflow: .dropOldest,
            stage: DataTrackStage(),
        )
        drain.attach(sendTarget: channel)
    }

    /// One packet per write, tagged for identification.
    private func frame(_ tag: UInt8, packets: Int = 1, packetSize: Int = 100) -> [Data] {
        (0 ..< packets).map { _ in Data(repeating: tag, count: packetSize) }
    }

    /// Waits for the drain's loop, which runs as a Task: submissions land asynchronously, and a
    /// fixed sleep flakes when other suites have the cooperative pool busy.
    private func until(
        _ description: Comment,
        _ condition: @Sendable () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) async throws {
        for _ in 0 ..< 400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("timed out waiting for: \(description)", sourceLocation: sourceLocation)
    }

    /// Gives the loop a chance to act before asserting that it did *not* — a lenient check by
    /// nature, unlike ``until(_:_:sourceLocation:)``.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    /// Reports the transport's drain, the way the buffered-amount callback does.
    private func drainBuffer() {
        drain.reportDrained(channel.flush())
    }

    /// Pushes the buffer past the low-water mark. Frame `0` goes out first and shows up in `sent`;
    /// the mirror only counts what the drain has handed over, so filling it means actually sending.
    private func fillBuffer() async throws {
        drain.submit(frame(0, packetSize: Int(Self.mark) + 1))
        try await until("the filling frame to be sent") { channel.tags == [0] }
    }

    @Test func sendsImmediatelyWithHeadroom() async throws {
        drain.submit(frame(1, packets: 3))
        try await until("all three writes to be sent") { channel.sent.count == 3 }
    }

    /// The whole group goes out even when it is far larger than the buffer headroom: writes are
    /// metered per drain instead of dumped, so there is no sender-imposed max frame size (all three
    /// SDKs share this property — JS by blocking the producer, Rust/Swift by metering).
    @Test func largeGroupStreamsWithinHeadroom() async throws {
        let packetSize = 64000
        drain.submit(frame(1, packets: 50, packetSize: packetSize))
        try await until("the first write to be sent") { !channel.sent.isEmpty }

        var rounds = 0
        while channel.sent.count < 50, rounds < 100 {
            // Each drain admits exactly one over-watermark write, so the buffer never holds more
            // than one write beyond the low-water mark.
            #expect(channel.outstanding <= Self.mark + UInt64(packetSize))
            let before = channel.sent.count
            drainBuffer()
            try await until("write \(before + 1) to be sent") { channel.sent.count > before }
            rounds += 1
        }
        #expect(channel.sent.count == 50)
    }

    /// A newer group evicts the queued (not yet started) one — freshest wins. This is the point of
    /// deliberate divergence from JS, which blocks the producer here instead of evicting; matches
    /// rust-sdks.
    @Test func dropsOldestQueuedGroup() async throws {
        try await fillBuffer()
        drain.submit(frame(1))
        drain.submit(frame(2))
        try await settle()
        #expect(channel.tags == [0], "both groups wait behind the full buffer")

        drainBuffer()
        try await until("the newer group to be sent") { channel.tags == [0, 2] }
    }

    /// A group being handed over is never abandoned midway: its remaining writes go out before a
    /// newer group, and writes of two groups never interleave. (The invariant all three SDKs agree
    /// on — "partial frames are never left on the wire".)
    @Test func inFlightGroupCompletesBeforeNewerGroup() async throws {
        // Packet size above the watermark: each round admits one write.
        drain.submit(frame(1, packets: 3, packetSize: 64000))
        try await until("the first write to be sent") { channel.sent.count == 1 }

        drain.submit(frame(2, packets: 2, packetSize: 64000))

        var rounds = 0
        while channel.sent.count < 5, rounds < 100 {
            let before = channel.sent.count
            drainBuffer()
            try await until("write \(before + 1) to be sent") { channel.sent.count > before }
            rounds += 1
        }
        #expect(channel.tags == [1, 1, 1, 2, 2])
    }

    /// Attaching a channel drops groups queued for the previous one (the analog of JS's
    /// `invalidateWaiters` on handle replacement — stale frames belong to a dead transport).
    @Test func attachClearsQueuedGroups() async throws {
        try await fillBuffer()
        drain.submit(frame(1))
        try await settle()

        let replacement = FakeSendChannel()
        drain.attach(sendTarget: replacement)
        try await settle()
        #expect(replacement.sent.isEmpty, "the queued group belonged to the previous channel")

        // The mirror starts over with the new channel, so a fresh group goes straight out even
        // though the previous channel was over its mark.
        drain.submit(frame(2))
        try await until("the fresh group to reach the new channel") { replacement.tags == [2] }
    }

    /// A rejected send drops the rest of the group without wedging the drain.
    @Test func rejectedSendDropsGroupOnly() async throws {
        channel.acceptsSends = false
        drain.submit(frame(1, packets: 3))
        try await settle()
        #expect(channel.sent.isEmpty)

        channel.acceptsSends = true
        drain.submit(frame(2))
        try await until("the next group to be sent") { channel.tags == [2] }
    }

    /// An empty batch must not evict a queued group.
    @Test func emptyBatchIsIgnored() async throws {
        try await fillBuffer()
        drain.submit(frame(1))
        drain.submit([])
        try await settle()

        drainBuffer()
        try await until("the queued group to survive the empty batch") { channel.tags == [0, 1] }
    }

    /// Nothing is sent while the channel is closed; opening drains the queue.
    @Test func queuedGroupDrainsOnceOpen() async throws {
        channel.isOpen = false
        drain.attach(sendTarget: channel)
        drain.submit(frame(1))
        try await settle()
        #expect(channel.sent.isEmpty)

        channel.isOpen = true
        // A zero-byte drain report is the cheapest way to make the loop re-run its queue.
        drain.reportDrained(0)
        try await until("the queued group to drain once open") { channel.tags == [1] }
    }
}

/// Under ``SendOverflow/dropOldest`` no submitter passes a continuation today, so these pin the
/// defensive path rather than an intended one: a write that gets dropped must still settle whatever
/// was waiting on it, because a dropped continuation strands its caller forever.
@Suite(.tags(.dataChannel))
struct DropOldestContinuationTests {
    private static let mark: UInt64 = 8 * 1024

    private let channel = FakeSendChannel()
    private let drain: DataChannelDrain<DataTrackStage>

    init() {
        drain = DataChannelDrain(
            label: "test",
            lowWaterMark: Self.mark,
            overflow: .dropOldest,
            stage: DataTrackStage(),
        )
        drain.attach(sendTarget: channel)
    }

    /// Fills the buffer so submitted groups queue instead of going straight out.
    private func fillBuffer() async throws {
        drain.submit([Data(repeating: 0, count: Int(Self.mark) + 1)])
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    private func submitWaiting(_ tag: UInt8) -> Task<Void, any Error> {
        Task {
            try await withCheckedThrowingContinuation { continuation in
                drain.submit([Data(repeating: tag, count: 100)], continuation: continuation)
            }
        }
    }

    @Test func evictionSettlesTheDisplacedWaiter() async throws {
        try await fillBuffer()

        let displaced = submitWaiting(1)
        try await Task.sleep(nanoseconds: 50_000_000)

        // A newer group evicts the queued one; its waiter must not be left suspended.
        drain.submit([Data(repeating: 2, count: 100)])

        await #expect {
            try await displaced.value
        } throws: { ($0 as? LiveKitError)?.type == .cancelled }
    }

    @Test func channelSwapSettlesQueuedWaiters() async throws {
        try await fillBuffer()

        let queued = submitWaiting(1)
        try await Task.sleep(nanoseconds: 50_000_000)

        drain.attach(sendTarget: FakeSendChannel())

        await #expect {
            try await queued.value
        } throws: { ($0 as? LiveKitError)?.type == .cancelled }
    }

    @Test func teardownSettlesQueuedWaiters() async throws {
        try await fillBuffer()

        let queued = submitWaiting(1)
        try await Task.sleep(nanoseconds: 50_000_000)

        drain.reset(throwing: LiveKitError(.invalidState, message: "torn down"))

        await #expect {
            try await queued.value
        } throws: { ($0 as? LiveKitError)?.type == .invalidState }
    }
}
