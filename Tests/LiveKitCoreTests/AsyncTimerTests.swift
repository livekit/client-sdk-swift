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

/// `AsyncTimer` drives its loop from `Task.detached(priority: .utility)`, so the
/// only guarantee it offers is "fires no *earlier* than the interval". Every
/// "did fire" assertion here therefore waits for the event with a generous
/// deadline (`ConcurrentCounter.wait(untilAtLeast:)`) instead of sleeping a fixed
/// multiple of the interval, and every "did not fire" assertion is bounded so
/// sleep overshoot can't manufacture a fire.
@Suite(.tags(.concurrency))
struct AsyncTimerTests {
    /// Short enough to keep the suite fast, long enough that one deferred wake-up
    /// doesn't change the outcome.
    private static let interval: TimeInterval = 0.05

    @Test func startIfStoppedFiresWhileRepeatedlyArmed() async throws {
        let counter = ConcurrentCounter()
        let timer = AsyncTimer(interval: 0.2)
        timer.setTimerBlock { _ = await counter.increment() }

        // Keep re-arming every 20ms until it fires: `startIfStopped` must leave the
        // in-flight countdown alone, so the first arm's timeout still elapses.
        let deadline = Date().addingTimeInterval(10)
        while await counter.getCount() == 0, Date() < deadline {
            timer.startIfStopped()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        timer.cancel()

        #expect(await counter.getCount() >= 1)
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

    @Test func cancelStopsFiring() async throws {
        let counter = ConcurrentCounter()
        let timer = AsyncTimer(interval: Self.interval)
        timer.setTimerBlock { _ = await counter.increment() }
        timer.restart()

        #expect(await counter.wait(untilAtLeast: 1) >= 1) // it actually ran
        timer.cancel()

        // Let any in-flight invocation settle before sampling.
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterCancel = await counter.getCount()

        try await Task.sleep(nanoseconds: 500_000_000) // 10 intervals
        #expect(await counter.getCount() == afterCancel) // nothing fired after cancel
    }

    @Test func concurrentArmingLeavesSingleLoop() async throws {
        let counter = ConcurrentCounter()
        let timer = AsyncTimer(interval: Self.interval)
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
        try await Task.sleep(nanoseconds: 275_000_000)
        timer.cancel()
        let elapsed = Date().timeIntervalSince(start)
        let count = await counter.getCount()

        // A single loop can fire at most `elapsed / interval` times. Normalizing by
        // the *measured* elapsed time rather than the requested sleep keeps this
        // bound valid when the host defers wake-ups; the orphan bug spawned dozens
        // of concurrent loops, so a 3x allowance still trips on it.
        let singleLoopBound = elapsed / Self.interval + 1
        #expect(Double(count) <= singleLoopBound * 3,
                "\(count) fires in \(elapsed)s exceeds what a single loop can produce")
    }

    @Test func blockCancellingOwnTimerFiresOnce() async throws {
        // Mirrors the ping-timeout path: the block cancels its own timer (via cleanUp).
        // Must fire exactly once and not deadlock on the state lock.
        let counter = ConcurrentCounter()
        let timer = AsyncTimer(interval: Self.interval)
        timer.setTimerBlock { [weak timer] in
            _ = await counter.increment()
            timer?.cancel()
        }
        timer.restart()

        #expect(await counter.wait(untilAtLeast: 1) >= 1)
        try await Task.sleep(nanoseconds: 500_000_000) // 10 intervals if it didn't stop
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
        let timer = AsyncTimer(interval: Self.interval)
        timer.setTimerBlock { _ = await first.increment() }
        timer.restart()

        #expect(await first.wait(untilAtLeast: 1) >= 1) // first block fires
        timer.setTimerBlock { _ = await second.increment() }
        #expect(await second.wait(untilAtLeast: 1) >= 1) // the updated block took effect
        timer.cancel()
    }

    @Test func deinitStopsTimer() async throws {
        let counter = ConcurrentCounter()
        do {
            let timer = AsyncTimer(interval: Self.interval)
            timer.setTimerBlock { _ = await counter.increment() }
            timer.restart()
            // Wait for a fire *before* releasing, so the assertion below doesn't
            // depend on the timer having been scheduled within a fixed window.
            #expect(await counter.wait(untilAtLeast: 1) >= 1)
        } // timer released here

        // Let the in-flight invocation finish and deinit cancel the loop.
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterRelease = await counter.getCount()

        try await Task.sleep(nanoseconds: 500_000_000) // 10 intervals
        #expect(await counter.getCount() == afterRelease) // deinit stopped it
    }

    @Test func continuesFiringAfterBlockThrows() async {
        struct BlockError: Error {}
        let counter = ConcurrentCounter()
        let timer = AsyncTimer(interval: Self.interval)
        timer.setTimerBlock {
            // First invocation throws; the loop must catch, log, and keep going.
            if await counter.increment() == 0 { throw BlockError() }
        }
        timer.restart()

        #expect(await counter.wait(untilAtLeast: 2) >= 2) // fired again after the throw
        timer.cancel()
    }

    @Test func startIfStoppedReArmsAfterCancel() async throws {
        let counter = ConcurrentCounter()
        let timer = AsyncTimer(interval: Self.interval)
        timer.setTimerBlock { _ = await counter.increment() }

        timer.startIfStopped()
        #expect(await counter.wait(untilAtLeast: 1) >= 1)
        timer.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterCancel = await counter.getCount()

        timer.startIfStopped() // cancel cleared the task, so this re-arms
        #expect(await counter.wait(untilAtLeast: afterCancel + 1) > afterCancel) // fired again after re-arm
        timer.cancel()
    }
}
