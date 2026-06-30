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
}
