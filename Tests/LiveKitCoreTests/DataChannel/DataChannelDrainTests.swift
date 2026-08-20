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
import Testing

#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

// MARK: - Shared fixture

/// Stands in for the channel the drain sends through. Reads come from the test's task while writes
/// come from the drain's loop, so the state lives in a `StateSync` — the SDK's own primitive,
/// rather than a lock of the test's own.
final class FakeSendChannel: DrainSendChannel, Sendable {
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

    func send(_ payload: Data) -> Bool {
        _state.mutate { state in
            guard state.acceptsSends else { return false }
            state.sent.append(payload)
            state.outstanding += UInt64(payload.count)
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

/// The one place the drain-under-test is built, so a signature or watermark change lands once.
enum DrainFixture {
    static let mark: UInt64 = 8 * 1024

    static func makeDrain(
        onBufferStatusChange: @escaping @Sendable (Bool) -> Void = { _ in },
    ) -> DataChannelDrain<DataTrackStage> {
        DataChannelDrain(
            label: "test",
            lowWaterMark: mark,
            overflow: .dropOldest,
            stage: DataTrackStage(),
            onBufferStatusChange: onBufferStatusChange,
        )
    }

    /// One packet per write, tagged for identification.
    static func frame(_ tag: UInt8, packets: Int = 1, packetSize: Int = 100) -> [Data] {
        (0 ..< packets).map { _ in Data(repeating: tag, count: packetSize) }
    }
}

extension DataChannelDrain where Stage == DataTrackStage {
    /// Awaited FIFO barrier: an empty input resolves inside the loop after every prior event has
    /// been processed, so an assertion made after this is exact — positive or negative — where a
    /// fixed sleep is a flake (loop starved) or a lie (loop never ran).
    func flushEvents() async throws {
        try await send([])
    }

    /// Pushes the buffer past the low-water mark. Frame `0` goes out first and shows up in `sent`;
    /// the mirror only counts what the drain has handed over, so filling it means actually sending.
    func fillBuffer(of channel: FakeSendChannel) async throws {
        submit(DrainFixture.frame(0, packetSize: Int(DrainFixture.mark) + 1))
        try await poll(for: "the filling frame to be sent") { channel.tags == [0] }
    }
}

// MARK: - Queue semantics

/// Pins ``DataChannelDrain``'s queue semantics under ``SendOverflow/dropOldest`` (what the
/// data-track and lossy channels use). Deliberately aligned with rust-sdks' `DataChannelSender` —
/// drop-oldest with a capacity-one group, whole-group atomicity, writes metered on buffered-amount
/// events — and deliberately *not* with client-sdk-js, which has no app-level queue and drops the
/// incoming payload instead (its engine awaits sends, so overload backpressures the producer;
/// Swift's data-track producer is a fire-and-forget FFI callback, so freshest-wins is used).
@Suite(.tags(.dataChannel, .dataTrack))
struct DataChannelDrainTests {
    private let channel = FakeSendChannel()
    private let drain = DrainFixture.makeDrain()

    init() {
        drain.attach(sendTarget: channel)
    }

    @Test func sendsImmediatelyWithHeadroom() async throws {
        drain.submit(DrainFixture.frame(1, packets: 3))
        try await drain.flushEvents()
        #expect(channel.sent.count == 3)
    }

    /// The whole group goes out even when it is far larger than the buffer headroom: writes are
    /// metered per drain instead of dumped, so there is no sender-imposed max frame size.
    @Test(.spec("https://github.com/livekit/rust-sdks/blob/f9c47c5a/livekit/src/rtc_engine/dc_sender.rs#L204"))
    func largeGroupStreamsWithinHeadroom() async throws {
        let packetSize = 64000
        drain.submit(DrainFixture.frame(1, packets: 50, packetSize: packetSize))
        try await poll(for: "the first write to be sent") { channel.sent.count == 1 }

        while channel.sent.count < 50 {
            // Each drain admits exactly one over-watermark write, so the buffer never holds more
            // than one write beyond the low-water mark.
            #expect(channel.outstanding <= DrainFixture.mark + UInt64(packetSize))
            let before = channel.sent.count
            drain.reportDrained(channel.flush())
            try await poll(for: "write \(before + 1) to be sent") { channel.sent.count > before }
        }
        #expect(channel.sent.count == 50)
    }

    /// A newer group evicts the queued (not yet started) one — freshest wins, as in rust-sdks'
    /// capacity-one `DataTrackSendQueue`.
    @Test(.spec("https://github.com/livekit/rust-sdks/blob/f9c47c5a/livekit/src/rtc_engine/dc_sender.rs#L36"))
    func dropsOldestQueuedGroup() async throws {
        try await drain.fillBuffer(of: channel)
        drain.submit(DrainFixture.frame(1))
        drain.submit(DrainFixture.frame(2))
        try await drain.flushEvents()
        #expect(channel.tags == [0], "both groups wait behind the full buffer")

        drain.reportDrained(channel.flush())
        try await poll(for: "the newer group to be sent") { channel.tags == [0, 2] }
    }

    /// A group being handed over is never abandoned midway: its remaining writes go out before a
    /// newer group, and writes of two groups never interleave. (The invariant every SDK's frame
    /// sender agrees on — "partial frames are never left on the wire".)
    @Test func inFlightGroupCompletesBeforeNewerGroup() async throws {
        // Packet size above the watermark: each round admits one write.
        drain.submit(DrainFixture.frame(1, packets: 3, packetSize: 64000))
        try await poll(for: "the first write to be sent") { channel.sent.count == 1 }

        drain.submit(DrainFixture.frame(2, packets: 2, packetSize: 64000))

        while channel.sent.count < 5 {
            let before = channel.sent.count
            drain.reportDrained(channel.flush())
            try await poll(for: "write \(before + 1) to be sent") { channel.sent.count > before }
        }
        #expect(channel.tags == [1, 1, 1, 2, 2])
    }

    /// Attaching a channel drops groups queued for the previous one — stale frames belong to a
    /// dead transport.
    @Test func attachClearsQueuedGroups() async throws {
        try await drain.fillBuffer(of: channel)
        drain.submit(DrainFixture.frame(1))

        let replacement = FakeSendChannel()
        drain.attach(sendTarget: replacement)
        try await drain.flushEvents()
        #expect(replacement.sent.isEmpty, "the queued group belonged to the previous channel")

        // The mirror starts over with the new channel, so a fresh group goes straight out even
        // though the previous channel was over its mark.
        drain.submit(DrainFixture.frame(2))
        try await poll(for: "the fresh group to reach the new channel") { replacement.tags == [2] }
    }

    /// A rejected send drops the rest of the group without wedging the drain.
    @Test func rejectedSendDropsGroupOnly() async throws {
        channel.acceptsSends = false
        drain.submit(DrainFixture.frame(1, packets: 3))
        try await drain.flushEvents()
        #expect(channel.sent.isEmpty)

        channel.acceptsSends = true
        drain.submit(DrainFixture.frame(2))
        try await poll(for: "the next group to be sent") { channel.tags == [2] }
    }

    /// An empty batch must not evict a queued group. (It is also the FIFO barrier the other tests
    /// lean on, which this pins.)
    @Test func emptyBatchIsIgnored() async throws {
        try await drain.fillBuffer(of: channel)
        drain.submit(DrainFixture.frame(1))
        drain.submit([])
        try await drain.flushEvents()

        drain.reportDrained(channel.flush())
        try await poll(for: "the queued group to survive the empty batch") { channel.tags == [0, 1] }
    }

    /// While the channel is still opening, a queued group stays in the evictable slot — promoted
    /// too early, eviction can't reach it and the stale group ships ahead of its replacement once
    /// the channel opens, violating freshest-wins exactly in the connect/reconnect window.
    @Test func newerGroupEvictsWhileChannelIsStillOpening() async throws {
        channel.isOpen = false
        drain.attach(sendTarget: channel)

        drain.submit(DrainFixture.frame(1))
        try await drain.flushEvents()
        drain.submit(DrainFixture.frame(2))
        try await drain.flushEvents()
        #expect(channel.sent.isEmpty)

        channel.isOpen = true
        drain.reportDrained(0)
        try await poll(for: "only the newest group to ship") { channel.tags == [2] }
        try await drain.flushEvents()
        #expect(channel.tags == [2], "the evicted group must not trail in later")
    }

    /// Nothing is sent while the channel is closed; opening drains the queue.
    @Test func queuedGroupDrainsOnceOpen() async throws {
        channel.isOpen = false
        drain.attach(sendTarget: channel)
        drain.submit(DrainFixture.frame(1))
        try await drain.flushEvents()
        #expect(channel.sent.isEmpty)

        channel.isOpen = true
        // A zero-byte drain report is the cheapest way to make the loop re-run its queue.
        drain.reportDrained(0)
        try await poll(for: "the queued group to drain once open") { channel.tags == [1] }
    }
}

// MARK: - Continuation settlement

/// How a drop-oldest channel settles a waiting submitter. Dropping under backpressure is what the
/// policy promises, so those waiters are *resolved*; only the session ending fails them. Matches
/// the outcome of `sendLossyBytes`' 'drop' behaviour in client-sdk-js, which returns normally and
/// counts the drop (js drops the incoming payload where this drain keeps the freshest).
@Suite(.tags(.dataChannel))
struct DropOldestContinuationTests {
    private let channel = FakeSendChannel()
    private let drain = DrainFixture.makeDrain()

    init() {
        drain.attach(sendTarget: channel)
    }

    private func sendAsync(_ tag: UInt8) -> Task<Void, any Error> {
        Task { try await drain.send(DrainFixture.frame(tag)) }
    }

    @Test(.spec("https://github.com/livekit/client-sdk-js/blob/499c8420/src/room/RTCEngine.ts#L1458"))
    func evictionResolvesTheDisplacedWaiter() async throws {
        try await drain.fillBuffer(of: channel)

        let displaced = sendAsync(1)
        try await drain.flushEvents()

        // A newer group evicts the queued one; its waiter must not be left suspended.
        drain.submit(DrainFixture.frame(2))

        try await displaced.value
    }

    @Test func channelSwapResolvesQueuedWaiters() async throws {
        try await drain.fillBuffer(of: channel)

        let queued = sendAsync(1)
        try await drain.flushEvents()

        drain.attach(sendTarget: FakeSendChannel())

        try await queued.value
    }

    /// A rejected send must settle its waiter exactly once: the failed write used to stay at the
    /// queue's head after being failed, so the drop-the-rest-of-the-group cleanup settled the same
    /// continuation a second time — a "SWIFT TASK CONTINUATION MISUSE" trap on the default (lossy)
    /// publish path. Passing at all is the assertion; a double resume crashes the test process.
    @Test func rejectedSendFailsItsWaiterExactlyOnce() async throws {
        channel.acceptsSends = false

        let waiter = sendAsync(1)

        await #expect {
            try await waiter.value
        } throws: { ($0 as? LiveKitError)?.type == .invalidState }

        // The drain is not wedged: a later group still ships.
        channel.acceptsSends = true
        drain.submit(DrainFixture.frame(2))
        try await poll(for: "the next group to be sent") { channel.tags == [2] }
    }

    @Test func teardownFailsQueuedWaiters() async throws {
        try await drain.fillBuffer(of: channel)

        let queued = sendAsync(1)
        try await drain.flushEvents()

        drain.reset(throwing: LiveKitError(.invalidState, message: "torn down"))

        await #expect {
            try await queued.value
        } throws: { ($0 as? LiveKitError)?.type == .invalidState }
    }
}

// MARK: - Buffer status

/// Buffer status is published on a transition only, never per change in the amount buffered — the
/// same contract `updateAndEmitDCBufferStatus` gives `DCBufferStatusChanged` in client-sdk-js.
@Suite(.tags(.dataChannel))
struct BufferStatusReportingTests {
    private let channel = FakeSendChannel()
    private let reports = StateSync<[Bool]>([])
    private let drain: DataChannelDrain<DataTrackStage>

    init() {
        let reports = reports
        drain = DrainFixture.makeDrain(onBufferStatusChange: { isLow in
            reports.mutate { $0.append(isLow) }
        })
        drain.attach(sendTarget: channel)
    }

    @Test(.spec("https://github.com/livekit/client-sdk-js/blob/499c8420/src/room/RTCEngine.ts#L1512"))
    func reportsOnlyTransitions() async throws {
        // Below the mark throughout: nothing to report.
        drain.submit(DrainFixture.frame(1))
        try await drain.flushEvents()
        #expect(reports.copy().isEmpty)

        // Over the mark — one report.
        drain.submit(DrainFixture.frame(2, packetSize: Int(DrainFixture.mark) + 1))
        try await drain.flushEvents()
        #expect(reports.copy() == [false])

        // Still over the mark after another partial drain — no second report.
        drain.reportDrained(10)
        try await drain.flushEvents()
        #expect(reports.copy() == [false])

        // Back under — one more.
        drain.reportDrained(channel.flush())
        try await drain.flushEvents()
        #expect(reports.copy() == [false, true])
    }

    /// A channel swap clears the mirror, so the status returns to low if it was not already.
    @Test func swapRestoresTheLowStatus() async throws {
        drain.submit(DrainFixture.frame(1, packetSize: Int(DrainFixture.mark) + 1))
        try await drain.flushEvents()
        #expect(reports.copy() == [false])

        drain.attach(sendTarget: FakeSendChannel())
        try await drain.flushEvents()
        #expect(reports.copy() == [false, true])
    }

    /// Teardown restores the low status too: an app that backed off on `isLow == false` must not
    /// wait forever for the recovering transition on a permanent disconnect.
    @Test func teardownRestoresTheLowStatus() async throws {
        drain.submit(DrainFixture.frame(1, packetSize: Int(DrainFixture.mark) + 1))
        try await drain.flushEvents()
        #expect(reports.copy() == [false])

        drain.reset()
        try await poll(for: "the recovering transition") { reports.copy() == [false, true] }
    }
}
