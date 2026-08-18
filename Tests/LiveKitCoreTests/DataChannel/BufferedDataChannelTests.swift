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

/// Unit coverage for the buffered-amount mirror and the headroom latch. No peer connection
/// involved: the type takes drained-byte reports rather than reading them off a channel, which
/// is what makes it testable at all.
@Suite(.tags(.dataChannel))
struct BufferedDataChannelTests {
    private static let mark: UInt64 = 1024

    private func makeChannel(waitTimeout: TimeInterval = 5) -> BufferedDataChannel {
        BufferedDataChannel(label: "test", lowWaterMark: Self.mark, waitTimeout: waitTimeout)
    }

    // MARK: - Mirror

    @Test func startsWithHeadroom() {
        #expect(makeChannel().hasHeadroom)
    }

    @Test func headroomHoldsUpToAndIncludingTheMark() {
        let channel = makeChannel()
        channel.didSend(Int(Self.mark))
        #expect(channel.hasHeadroom, "the mark itself is still sendable")

        channel.didSend(1)
        #expect(!channel.hasHeadroom)
    }

    @Test func drainedBytesRestoreHeadroom() {
        let channel = makeChannel()
        channel.didSend(Int(Self.mark) + 512)
        #expect(!channel.hasHeadroom)

        channel.didDrain(256)
        #expect(!channel.hasHeadroom, "still above the mark")

        channel.didDrain(256)
        #expect(channel.hasHeadroom)
    }

    /// A report larger than the mirror can't be honored; clamping to zero keeps the gate open
    /// rather than wedging the drain on an underflowed count.
    @Test func overReportSelfHealsToZero() {
        let channel = makeChannel()
        channel.didSend(64)
        channel.didDrain(4096)
        #expect(channel.hasHeadroom)

        // Zero, not a wrapped `UInt64`: another mark's worth must still fit.
        channel.didSend(Int(Self.mark))
        #expect(channel.hasHeadroom)
        channel.didSend(1)
        #expect(!channel.hasHeadroom)
    }

    @Test func resetClearsTheMirror() {
        let channel = makeChannel()
        channel.didSend(Int(Self.mark) * 4)
        #expect(!channel.hasHeadroom)

        channel.reset()
        #expect(channel.hasHeadroom)
    }

    // MARK: - Headroom latch

    @Test func waitReturnsImmediatelyWhenReadyAndBelowTheMark() async throws {
        let channel = makeChannel()
        channel.setReady(true)
        try await channel.waitForHeadroom()
    }

    @Test func waitSuspendsUntilTheBufferDrains() async throws {
        let channel = makeChannel()
        channel.setReady(true)
        channel.didSend(Int(Self.mark) + 1)

        let waiter = Task { try await channel.waitForHeadroom() }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(channel.hasHeadroom == false)

        channel.didDrain(UInt64(Self.mark) + 1)
        try await waiter.value
    }

    /// Readiness is the other half of the gate: a producer must not wake into a channel that
    /// cannot accept bytes, even when the buffer is empty.
    @Test func waitSuspendsWhileNotReady() async throws {
        let channel = makeChannel()

        let waiter = Task { try await channel.waitForHeadroom() }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!waiter.isCancelled)

        channel.setReady(true)
        try await waiter.value
    }

    @Test func drainWhileNotReadyDoesNotWakeWaiters() async throws {
        let channel = makeChannel()
        channel.didSend(Int(Self.mark) + 1)

        let waiter = Task { try await channel.waitForHeadroom() }
        try await Task.sleep(nanoseconds: 50_000_000)

        channel.didDrain(UInt64(Self.mark) + 1)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Draining alone is not enough — the channel was never reported ready.
        waiter.cancel()
        await #expect { try await waiter.value } throws: { _ in true }
    }

    @Test func becomingUnreadyClosesTheGateAgain() async throws {
        let channel = makeChannel()
        channel.setReady(true)
        try await channel.waitForHeadroom()

        channel.setReady(false)
        let waiter = Task { try await channel.waitForHeadroom() }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!waiter.isCancelled)

        channel.setReady(true)
        try await waiter.value
    }

    @Test func resetFailsWaitersWithTheProvidedError() async throws {
        let channel = makeChannel()
        channel.setReady(true)
        channel.didSend(Int(Self.mark) + 1)

        let waiter = Task { try await channel.waitForHeadroom() }
        try await Task.sleep(nanoseconds: 50_000_000)

        channel.reset(throwing: LiveKitError(.invalidState, message: "torn down"))
        await #expect {
            try await waiter.value
        } throws: { ($0 as? LiveKitError)?.type == .invalidState }
    }

    @Test func waitTimesOutWhenTheBufferNeverDrains() async {
        let channel = makeChannel()
        channel.setReady(true)
        channel.didSend(Int(Self.mark) + 1)

        await #expect {
            try await channel.waitForHeadroom(timeout: 0.1)
        } throws: { ($0 as? LiveKitError)?.type == .timedOut }
    }

    @Test func waitHonorsTaskCancellation() async throws {
        let channel = makeChannel()
        channel.setReady(true)
        channel.didSend(Int(Self.mark) + 1)

        let waiter = Task { try await channel.waitForHeadroom() }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()

        await #expect {
            try await waiter.value
        } throws: { ($0 as? LiveKitError)?.type == .cancelled }
    }

    @Test func everyWaiterWakesOnOneDrain() async throws {
        let channel = makeChannel()
        channel.setReady(true)
        channel.didSend(Int(Self.mark) + 1)

        let waiters = (0 ..< 4).map { _ in Task { try await channel.waitForHeadroom() } }
        try await Task.sleep(nanoseconds: 50_000_000)

        channel.didDrain(UInt64(Self.mark) + 1)
        for waiter in waiters {
            try await waiter.value
        }
    }
}
