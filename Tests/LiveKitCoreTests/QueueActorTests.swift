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
struct QueueActorTests {
    /// Records what a queue processes and holds element 0 until the test opens `gate`, so the test
    /// can act while a `resume()` drain is provably in progress.
    final class Recorder: Sendable {
        let processed = StateSync<[Int]>([])
        let zeroStarted = Gate()
        let gate = Gate()

        func makeQueue() -> QueueActor<Int> {
            QueueActor<Int> { [self] value in
                if value == 0 {
                    zeroStarted.open()
                    await gate.wait()
                }
                processed.mutate { $0.append(value) }
            }
        }
    }

    @Test func queueActor01() async {
        let queue = QueueActor<String> { print($0) }
        await queue.processIfResumed("Value 0")
        await queue.suspend()
        await queue.processIfResumed("Value 1")
        await queue.processIfResumed("Value 2")
        await queue.processIfResumed("Value 3")
        await print("Count: \(queue.count)")
        await queue.resume()
        await print("Count: \(queue.count)")
    }

    /// A value arriving while `resume()` drains the backlog is processed after it, not before.
    @Test func arrivalsDuringDrainKeepArrivalOrder() async {
        let recorder = Recorder()
        let queue = recorder.makeQueue()
        for value in 0 ..< 5 {
            await queue.processIfResumed(value)
        }
        #expect(await queue.count == 5)

        let drain = Task { await queue.resume() }
        await recorder.zeroStarted.wait()
        for value in 5 ..< 10 {
            await queue.processIfResumed(value)
        }
        recorder.gate.open()
        await drain.value

        #expect(recorder.processed.copy() == Array(0 ..< 10))
        #expect(await queue.count == 0)
    }

    /// A value that may not be enqueued is not held back by a drain.
    @Test func nonQueueableValuesBypassTheDrain() async {
        let recorder = Recorder()
        let queue = recorder.makeQueue()
        await queue.processIfResumed(0)
        await queue.processIfResumed(1)

        let drain = Task { await queue.resume() }
        await recorder.zeroStarted.wait()
        await queue.processIfResumed(2, elseEnqueue: false)
        recorder.gate.open()
        await drain.value

        #expect(recorder.processed.copy() == [2, 0, 1])
    }

    /// A second `resume()` during a drain neither duplicates nor interleaves the backlog.
    @Test func concurrentResumeProcessesEachElementOnce() async {
        let recorder = Recorder()
        let queue = recorder.makeQueue()
        for value in 0 ..< 10 {
            await queue.processIfResumed(value)
        }

        let drain = Task { await queue.resume() }
        await recorder.zeroStarted.wait()
        await queue.resume()
        recorder.gate.open()
        await drain.value

        #expect(recorder.processed.copy() == Array(0 ..< 10))
    }

    /// `clear()` during a drain drops what is still queued and stops the drain.
    @Test func clearStopsDrain() async {
        let recorder = Recorder()
        let queue = recorder.makeQueue()
        for value in 0 ..< 10 {
            await queue.processIfResumed(value)
        }

        let drain = Task { await queue.resume() }
        await recorder.zeroStarted.wait()
        await queue.clear()
        recorder.gate.open()
        await drain.value

        #expect(recorder.processed.copy() == [0])
        #expect(await queue.state == .suspended)
        #expect(await queue.count == 0)
    }
}
