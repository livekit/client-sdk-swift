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

    /// An empty batch must not evict a queued group — it is also the FIFO barrier the tests lean on.
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

    /// Starts a send and returns once its submit has reached the drain's event stream, so a
    /// `flushEvents()` that follows is a barrier behind it: `Task {}` alone may not have run yet.
    private func sendAsync(_ tag: UInt8) async -> Task<Void, any Error> {
        let (submitted, mark) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            try await withCheckedThrowingContinuation { continuation in
                drain.submit(DrainFixture.frame(tag), continuation: continuation)
                mark.finish()
            }
        }
        for await _ in submitted {}
        return task
    }

    @Test(.spec("https://github.com/livekit/client-sdk-js/blob/499c8420/src/room/RTCEngine.ts#L1458"))
    func evictionResolvesTheDisplacedWaiter() async throws {
        try await drain.fillBuffer(of: channel)

        let displaced = await sendAsync(1)
        try await drain.flushEvents()

        // A newer group evicts the queued one; its waiter must not be left suspended.
        drain.submit(DrainFixture.frame(2))

        try await displaced.value
    }

    @Test func channelSwapResolvesQueuedWaiters() async throws {
        try await drain.fillBuffer(of: channel)

        let queued = await sendAsync(1)
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

        let waiter = await sendAsync(1)

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

        let queued = await sendAsync(1)
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

// MARK: - Open latch

/// The send gate: ``DataChannelDrain/whenOpen`` and the loss it exists to prevent.
///
/// A drop-oldest channel has room for exactly one queued group, so "the channel has not opened
/// yet" and "the transport is saturated" produce the same eviction — except the first discards
/// writes the transport never even saw, and settles their submitters *successfully*. Everything
/// here uses the ``FakeSendChannel`` seam, so nothing depends on how fast SCTP comes up.
@Suite(.tags(.dataChannel, .dataTrack))
struct DataChannelOpenLatchTests {
    private let drain = DrainFixture.makeDrain()

    /// A never-attached drain must hold its waiters, not wave them through.
    @Test func latchIsArmedBeforeAnyChannelArrives() async {
        await #expect {
            try await drain.whenOpen.wait(timeout: 0.1)
        } throws: { ($0 as? LiveKitError)?.type == .timedOut }
    }

    @Test func latchFollowsTheAttachedChannel() async throws {
        let channel = FakeSendChannel()
        channel.isOpen = false
        drain.attach(sendTarget: channel)
        await #expect {
            try await drain.whenOpen.wait(timeout: 0.1)
        } throws: { ($0 as? LiveKitError)?.type == .timedOut }

        channel.isOpen = true
        drain.attach(sendTarget: channel)
        try await drain.whenOpen.wait(timeout: 1)
    }

    /// Teardown re-arms rather than resolving: without this a send issued after a disconnect sails
    /// through a latch the dead channel left resolved and parks in a drain that has nothing left
    /// to ship it.
    @Test func resetRearmsTheLatch() async throws {
        drain.attach(sendTarget: FakeSendChannel())
        try await drain.whenOpen.wait(timeout: 1)

        drain.reset()
        await #expect {
            try await drain.whenOpen.wait(timeout: 0.1)
        } throws: { ($0 as? LiveKitError)?.type == .timedOut }
    }

    /// A delegate callback that lands after teardown must not resolve the latch from the channel it
    /// was called for. The drain publishes the state of whatever it is pointing at *now*, so the
    /// torn-down channel still reporting `.open` cannot reopen a gate that teardown just closed —
    /// a send crossing one of those parks in a drain with no channel, where the next one evicts it
    /// and reports success.
    @Test func stateChangeArrivingAfterResetLeavesTheLatchArmed() async throws {
        let channel = FakeSendChannel()
        drain.attach(sendTarget: channel)
        try await drain.whenOpen.wait(timeout: 1)

        drain.reset()
        #expect(channel.isOpen, "the superseded channel has not been closed yet")

        drain.publishOpenState() // the callback for `channel`, arriving now

        await #expect {
            try await drain.whenOpen.wait(timeout: 0.1)
        } throws: { ($0 as? LiveKitError)?.type == .timedOut }
    }

    /// The defect, stated as a test. Five writes submitted while the channel is still opening leave
    /// only the last one — and the four that died reported success, which is why this was invisible
    /// in the logs for as long as it was.
    @Test func ungatedBurstBeforeOpenCollapsesToItsLastWrite() async throws {
        let channel = FakeSendChannel()
        channel.isOpen = false
        drain.attach(sendTarget: channel)

        // `submit`, not `send`: a parked write never settles, which is exactly the point — the
        // four that die here are settled *successfully* by the eviction, not by delivery.
        for tag in UInt8(1) ... 5 {
            drain.submit(DrainFixture.frame(tag))
        }
        try await drain.flushEvents()
        #expect(channel.sent.isEmpty, "nothing reaches a channel that is not open")

        channel.isOpen = true
        drain.reportDrained(0) // the wake-up the real delegate posts on `.open`
        try await poll(for: "the surviving write") { channel.tags == [5] }
    }

    /// With no transport there is nothing that could open a channel, so the gate has to turn the
    /// caller away rather than hold them for the latch's full 15 s and then report a `.timedOut`
    /// that says nothing about why.
    @Test(arguments: [Livekit_DataPacket_Kind.reliable, .lossy])
    func sendOnADisconnectedRoomFailsWithoutWaitingOutTheLatch(kind: Livekit_DataPacket_Kind) async {
        let room = Room()
        let started = Date()

        await #expect {
            try await room.send(dataPacket: .with { $0.kind = kind })
        } throws: { ($0 as? LiveKitError)?.type == .invalidState }

        #expect(Date().timeIntervalSince(started) < 1, "the gate must not wait on a latch nothing can resolve")
    }

    /// The gate must depend on the channel, not on the transport mode.
    ///
    /// A connected room with no transport is exactly the state the old gate fell through on: it
    /// opened with `guard case .subscriberPrimary = _state.transport else { return }`, which is
    /// false for both publisher-primary modes *and* for `nil`. Nothing can open a channel here, so
    /// the gate must not return. (That it waits on *this kind's* channel is
    /// ``DataChannelPairTests/openLatchesAreDistinctPerKind()``.)
    ///
    /// Raced inside one task group rather than observed from another task. Polling a waiter count
    /// from outside measures whether the SDK's task has been *scheduled*, which at the tail of a
    /// full suite it may not be for tens of seconds — verified: the probe showed the send unstarted
    /// after 30 s, on a room still `.connected`. Here, a gate that returns early beats the sleep
    /// and fails; a starved one loses to the sleep and passes, so slowness can never manufacture a
    /// red.
    @Test func sendGateDoesNotReturnWithoutAChannel() async {
        let room = Room()
        room._state.mutate { $0.connectionState = .connected }

        let gated = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await room.ensureDataChannelReady(kind: .lossy)
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return true
            }
            let first = await group.next() ?? true
            group.cancelAll()
            return first
        }

        #expect(gated, "The send gate must wait for the channel in every transport mode")
    }

    /// The same burst, gated the way `Room.send(dataPacket:)` gates it. Every write survives,
    /// because each submitter waits for the channel instead of racing the one before it.
    @Test func gatedBurstSurvivesAChannelThatOpensLate() async throws {
        let channel = FakeSendChannel()
        channel.isOpen = false
        drain.attach(sendTarget: channel)

        let senders = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for tag in UInt8(1) ... 5 {
                    group.addTask {
                        try await drain.whenOpen.wait(timeout: 5)
                        try await drain.send(DrainFixture.frame(tag))
                    }
                }
                try await group.waitForAll()
            }
        }
        await drain.whenOpen.waitForRegistration(count: 5)

        channel.isOpen = true
        drain.attach(sendTarget: channel)

        try await senders.value
        #expect(channel.sent.count == 5, "a gated burst loses nothing")
        #expect(Set(channel.tags) == Set(UInt8(1) ... 5))
    }
}

// MARK: - Teardown

/// What a submission arriving *after* teardown does. `.fail` settles what was queued when it ran,
/// and nothing attaches another channel afterwards, so a write that lands later has to be turned
/// away rather than parked — `Room.send` gates first, but the gate and the submission are separate
/// steps and a disconnect can land between them.
@Suite(.tags(.dataChannel))
struct DataChannelTeardownTests {
    private let drain = DrainFixture.makeDrain()

    @Test func sendAfterResetFailsInsteadOfParking() async throws {
        drain.attach(sendTarget: FakeSendChannel())
        drain.reset()
        try await drain.flushEvents()

        await #expect {
            try await drain.send(DrainFixture.frame(1))
        } throws: { ($0 as? LiveKitError)?.type == .invalidState }
    }

    /// The same "no channel" state before one has *ever* arrived means the opposite: connect is
    /// still in progress, so the write is queued rather than turned away. (This fixture is
    /// drop-oldest, so attaching then settles it as dropped — what matters here is that it was
    /// accepted, not failed.)
    @Test func sendBeforeFirstChannelIsNotTurnedAway() async throws {
        let send = Task { try await drain.send(DrainFixture.frame(1)) }
        try await drain.flushEvents()

        drain.attach(sendTarget: FakeSendChannel())
        try await send.value
    }
}
