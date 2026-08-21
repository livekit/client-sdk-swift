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

/// `AsyncTimer` only guarantees "fires no earlier than the interval", so "did
/// fire" assertions wait for the event and "did not fire" assertions are bounded
/// so sleep overshoot can't manufacture a fire.
/// Drives `AsyncTimer` ticks from the test instead of the scheduler.
private actor ManualSleeper {
    private var parked: [CheckedContinuation<Void, Never>] = []

    nonisolated var sleep: AsyncTimer.SleepFunction {
        { [weak self] _ in await self?.park() }
    }

    private func park() async {
        await withCheckedContinuation { parked.append($0) }
    }

    /// How many countdowns are currently waiting — one per live loop.
    var parkedCount: Int { parked.count }

    /// Releases every parked countdown. Also required before a test ends, so no
    /// checked continuation is left unresumed.
    func tickAll() {
        let waiters = parked
        parked = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForParked(_ count: Int, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while parked.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@Suite(.tags(.concurrency))
struct AsyncTimerTests {
    private static let interval: TimeInterval = 0.05

    @Test func startIfStoppedFiresWhileRepeatedlyArmed() async {
        let counter = ConcurrentCounter()
        let sleeper = ManualSleeper()
        let timer = AsyncTimer(interval: 0.2, sleep: sleeper.sleep)
        timer.setTimerBlock { _ = await counter.increment() }

        timer.startIfStopped()
        await sleeper.waitForParked(1)

        // Re-arming must leave the in-flight countdown alone rather than starting
        // another one, so exactly one stays parked.
        for _ in 0 ..< 25 {
            timer.startIfStopped()
        }
        #expect(await sleeper.parkedCount == 1)

        await sleeper.tickAll() // the original countdown elapses
        #expect(await counter.wait(untilAtLeast: 1) >= 1)

        timer.cancel()
        await sleeper.tickAll()
    }

    @Test func restartNeverFiresWhileRepeatedlyArmed() async throws {
        let counter = ConcurrentCounter()
        // Interval far larger than the arming window below, so a fire would mean the
        // countdown genuinely wasn't reset — not that a sleep overshot.
        let timer = AsyncTimer(interval: 5)
        timer.setTimerBlock { _ = await counter.increment() }

        let armingEnd = Date().addingTimeInterval(0.5)
        while Date() < armingEnd {
            timer.restart()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let firedWhileArming = await counter.getCount()
        timer.cancel()

        #expect(firedWhileArming == 0)
    }

    @Test func cancelStopsFiring() async {
        let counter = ConcurrentCounter()
        let sleeper = ManualSleeper()
        let timer = AsyncTimer(interval: Self.interval, sleep: sleeper.sleep)
        timer.setTimerBlock { _ = await counter.increment() }
        timer.restart()

        await sleeper.waitForParked(1)
        await sleeper.tickAll()
        #expect(await counter.wait(untilAtLeast: 1) >= 1) // it actually ran

        await sleeper.waitForParked(1) // parked again for the next cycle
        timer.cancel()
        let afterCancel = await counter.getCount()

        // Releasing further countdowns must not produce another invocation.
        await sleeper.tickAll()
        #expect(await counter.getCount() == afterCancel)
    }

    @Test func concurrentArmingLeavesSingleLoop() async throws {
        let counter = ConcurrentCounter()
        // 5ms rather than 50ms: the loop still races real time here, but fires often
        // enough that the liveness check below can't be starved out.
        let interval: TimeInterval = 0.005
        let timer = AsyncTimer(interval: interval)
        timer.setTimerBlock { _ = await counter.increment() }

        // Hammer with concurrent restart()/startIfStopped(): the previous design
        // could orphan a scheduling task here and run several loops at once.
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 50 {
                group.addTask { i.isMultiple(of: 2) ? timer.restart() : timer.startIfStopped() }
            }
        }

        let start = Date()
        #expect(await counter.wait(untilAtLeast: 1) >= 1) // a loop is running
        try await Task.sleep(nanoseconds: 100_000_000)
        timer.cancel()
        let elapsed = Date().timeIntervalSince(start)
        let count = await counter.getCount()

        // A single loop can fire at most `elapsed / interval` times. Normalizing by
        // the measured elapsed time keeps this valid when the host defers wake-ups;
        // the orphan bug spawned dozens of concurrent loops, so a 3x allowance
        // still trips on it.
        let singleLoopBound = elapsed / interval + 1
        #expect(Double(count) <= singleLoopBound * 3,
                "\(count) fires in \(elapsed)s exceeds what a single loop can produce")
    }

    @Test func blockCancellingOwnTimerFiresOnce() async {
        // Mirrors the ping-timeout path: the block cancels its own timer (via cleanUp).
        // Must fire exactly once and not deadlock on the state lock.
        let counter = ConcurrentCounter()
        let sleeper = ManualSleeper()
        let timer = AsyncTimer(interval: Self.interval, sleep: sleeper.sleep)
        timer.setTimerBlock { [weak timer] in
            _ = await counter.increment()
            timer?.cancel()
        }
        timer.restart()

        await sleeper.waitForParked(1)
        await sleeper.tickAll()
        #expect(await counter.wait(untilAtLeast: 1) >= 1)

        // Self-cancelling means the loop exits, so nothing parks for another cycle.
        await sleeper.tickAll()
        #expect(await counter.getCount() == 1)
    }

    @Test func concurrentRestartAndCancelLeaveNoOrphan() async throws {
        let counter = ConcurrentCounter()
        let timer = AsyncTimer(interval: Self.interval)
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
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterCancel = await counter.getCount()
        try await Task.sleep(nanoseconds: 500_000_000) // 10 intervals
        #expect(await counter.getCount() == afterCancel)
    }

    @Test func updatesBlockOnNextCycle() async {
        let first = ConcurrentCounter()
        let second = ConcurrentCounter()
        let sleeper = ManualSleeper()
        let timer = AsyncTimer(interval: Self.interval, sleep: sleeper.sleep)
        timer.setTimerBlock { _ = await first.increment() }
        timer.restart()

        // The loop reads the block before sleeping, so swapping it now must not
        // affect the countdown already in flight.
        await sleeper.waitForParked(1)
        timer.setTimerBlock { _ = await second.increment() }
        await sleeper.tickAll()
        #expect(await first.wait(untilAtLeast: 1) >= 1)
        #expect(await second.getCount() == 0)

        // The next cycle picks it up.
        await sleeper.waitForParked(1)
        await sleeper.tickAll()
        #expect(await second.wait(untilAtLeast: 1) >= 1)

        timer.cancel()
        await sleeper.tickAll()
    }

    @Test func deinitStopsTimer() async {
        let counter = ConcurrentCounter()
        let sleeper = ManualSleeper()
        do {
            let timer = AsyncTimer(interval: Self.interval, sleep: sleeper.sleep)
            timer.setTimerBlock { _ = await counter.increment() }
            timer.restart()
            await sleeper.waitForParked(1)
            await sleeper.tickAll()
            #expect(await counter.wait(untilAtLeast: 1) >= 1)
            await sleeper.waitForParked(1) // parked for the next cycle
        } // timer released here — deinit cancels the loop

        let afterRelease = await counter.getCount()
        // Releasing the parked countdown must find the loop cancelled.
        await sleeper.tickAll()
        #expect(await counter.getCount() == afterRelease)
    }

    @Test func continuesFiringAfterBlockThrows() async {
        struct BlockError: Error {}
        let counter = ConcurrentCounter()
        let sleeper = ManualSleeper()
        let timer = AsyncTimer(interval: Self.interval, sleep: sleeper.sleep)
        timer.setTimerBlock {
            // First invocation throws; the loop must catch, log, and keep going.
            if await counter.increment() == 0 { throw BlockError() }
        }
        timer.restart()

        await sleeper.waitForParked(1)
        await sleeper.tickAll()
        #expect(await counter.wait(untilAtLeast: 1) >= 1) // threw

        await sleeper.waitForParked(1) // the loop survived and parked again
        await sleeper.tickAll()
        #expect(await counter.wait(untilAtLeast: 2) >= 2) // fired again after the throw

        timer.cancel()
        await sleeper.tickAll()
    }

    @Test func startIfStoppedReArmsAfterCancel() async {
        let counter = ConcurrentCounter()
        let sleeper = ManualSleeper()
        let timer = AsyncTimer(interval: Self.interval, sleep: sleeper.sleep)
        timer.setTimerBlock { _ = await counter.increment() }

        timer.startIfStopped()
        await sleeper.waitForParked(1)
        await sleeper.tickAll()
        #expect(await counter.wait(untilAtLeast: 1) >= 1)

        await sleeper.waitForParked(1)
        timer.cancel()
        await sleeper.tickAll() // loop observes the cancel and exits
        let afterCancel = await counter.getCount()

        timer.startIfStopped() // cancel cleared the task, so this re-arms
        await sleeper.waitForParked(1)
        await sleeper.tickAll()
        #expect(await counter.wait(untilAtLeast: afterCancel + 1) > afterCancel) // fired again after re-arm
        timer.cancel()
    }
}
