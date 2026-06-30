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

@Suite(.tags(.concurrency))
struct AsyncTimerTests {
    @Test func startIfStoppedFiresWhileRepeatedlyArmed() async throws {
        let counter = ConcurrentCounter()
        let timer = AsyncTimer(interval: 0.2)
        timer.setTimerBlock { _ = await counter.increment() }

        // Arm every 20ms for ~500ms — ~25 arms across the 200ms timeout window.
        for _ in 0 ..< 25 {
            timer.startIfStopped()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        timer.cancel()

        // The first arm's countdown was never reset, so it fired at ~200ms.
        #expect(await counter.getCount() >= 1)
    }

    @Test func restartNeverFiresWhileRepeatedlyArmed() async throws {
        let counter = ConcurrentCounter()
        let timer = AsyncTimer(interval: 0.2)
        timer.setTimerBlock { _ = await counter.increment() }

        for _ in 0 ..< 25 {
            timer.restart()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let firedWhileArming = await counter.getCount()
        timer.cancel()

        #expect(firedWhileArming == 0)
    }

    @Test func cancelStopsFiring() async throws {
        let counter = ConcurrentCounter()
        let timer = AsyncTimer(interval: 0.05)
        timer.setTimerBlock { _ = await counter.increment() }
        timer.restart()

        try await Task.sleep(nanoseconds: 175_000_000) // ~3 intervals
        timer.cancel()

        // Let any in-flight invocation settle before sampling.
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterCancel = await counter.getCount()
        #expect(afterCancel >= 1) // it actually ran

        try await Task.sleep(nanoseconds: 200_000_000) // 4 more intervals
        #expect(await counter.getCount() == afterCancel) // nothing fired after cancel
    }

    @Test func concurrentArmingLeavesSingleLoop() async throws {
        let counter = ConcurrentCounter()
        let timer = AsyncTimer(interval: 0.05)
        timer.setTimerBlock { _ = await counter.increment() }

        // Hammer with concurrent restart()/startIfStopped(): the previous design
        // could orphan a scheduling task here and run several loops at once.
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 50 {
                group.addTask { i.isMultiple(of: 2) ? timer.restart() : timer.startIfStopped() }
            }
        }

        try await Task.sleep(nanoseconds: 275_000_000) // ~5 intervals for one loop
        timer.cancel()

        let count = await counter.getCount()
        #expect(count >= 1) // a loop is running
        // One loop fires ~5x here; the bound has headroom for sleep overshoot under
        // parallel CI load. The orphan bug spawned dozens of loops, so it still trips.
        #expect(count <= 15)
    }

    @Test func blockCancellingOwnTimerFiresOnce() async throws {
        // Mirrors the ping-timeout path: the block cancels its own timer (via cleanUp).
        // Must fire exactly once and not deadlock on the state lock.
        let counter = ConcurrentCounter()
        let timer = AsyncTimer(interval: 0.05)
        timer.setTimerBlock { [weak timer] in
            _ = await counter.increment()
            timer?.cancel()
        }
        timer.restart()

        try await Task.sleep(nanoseconds: 250_000_000) // ~5 intervals if it didn't stop
        #expect(await counter.getCount() == 1)
    }

    @Test func concurrentRestartAndCancelLeaveNoOrphan() async throws {
        let counter = ConcurrentCounter()
        let timer = AsyncTimer(interval: 0.05)
        timer.setTimerBlock { _ = await counter.increment() }

        // Interleave restart / startIfStopped / cancel concurrently.
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 60 {
                group.addTask {
                    switch i % 3 {
                    case 0: timer.restart()
                    case 1: timer.startIfStopped()
                    default: timer.cancel()
                    }
                }
            }
        }

        // Whatever the interleaving, a final cancel must stop every loop — no orphan survives.
        timer.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterCancel = await counter.getCount()
        try await Task.sleep(nanoseconds: 250_000_000) // 5 intervals
        #expect(await counter.getCount() == afterCancel)
    }

    @Test func updatesBlockOnNextCycle() async throws {
        let first = ConcurrentCounter()
        let second = ConcurrentCounter()
        let timer = AsyncTimer(interval: 0.05)
        timer.setTimerBlock { _ = await first.increment() }
        timer.restart()

        try await Task.sleep(nanoseconds: 120_000_000) // first block fires
        timer.setTimerBlock { _ = await second.increment() }
        try await Task.sleep(nanoseconds: 150_000_000) // swapped block fires
        timer.cancel()
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(await first.getCount() >= 1)
        #expect(await second.getCount() >= 1) // the updated block took effect
    }

    @Test func deinitStopsTimer() async throws {
        let counter = ConcurrentCounter()
        do {
            let timer = AsyncTimer(interval: 0.05)
            timer.setTimerBlock { _ = await counter.increment() }
            timer.restart()
            try await Task.sleep(nanoseconds: 120_000_000)
        } // timer released here

        // Let the in-flight invocation finish and deinit cancel the loop.
        try await Task.sleep(nanoseconds: 150_000_000)
        let afterRelease = await counter.getCount()
        #expect(afterRelease >= 1)

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await counter.getCount() == afterRelease) // deinit stopped it
    }

    @Test func continuesFiringAfterBlockThrows() async throws {
        struct BlockError: Error {}
        let counter = ConcurrentCounter()
        let timer = AsyncTimer(interval: 0.05)
        timer.setTimerBlock {
            // First invocation throws; the loop must catch, log, and keep going.
            if await counter.increment() == 0 { throw BlockError() }
        }
        timer.restart()

        try await Task.sleep(nanoseconds: 300_000_000) // ~6 intervals
        timer.cancel()
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(await counter.getCount() >= 2) // fired again after the throw
    }

    @Test func startIfStoppedReArmsAfterCancel() async throws {
        let counter = ConcurrentCounter()
        let timer = AsyncTimer(interval: 0.05)
        timer.setTimerBlock { _ = await counter.increment() }

        timer.startIfStopped()
        try await Task.sleep(nanoseconds: 120_000_000)
        timer.cancel()
        try await Task.sleep(nanoseconds: 80_000_000)
        let afterCancel = await counter.getCount()

        timer.startIfStopped() // cancel cleared isStarted, so this re-arms
        try await Task.sleep(nanoseconds: 150_000_000)
        timer.cancel()
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(await counter.getCount() > afterCancel) // fired again after re-arm
    }
}
