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

// MARK: - Test Observer

actor TestObserver {
    let id: String
    private(set) var processedItems: [Int] = []

    init(id: String = "test") {
        self.id = id
    }

    func recordItem(_ item: Int) {
        processedItems.append(item)
    }

    /// Waits until at least `count` items have been recorded, or `timeout` elapses.
    ///
    /// `subscribe` delivers on its own unstructured task, so "has it processed them yet" is a
    /// scheduling question, not a timing one. A fixed sleep answers it correctly only on an idle
    /// machine; on a loaded CI runner the task has simply not been scheduled yet, which is what
    /// made these assert against an empty or half-filled array. Polling still fails a genuine
    /// regression — nothing ever arrives — it just stops failing for being slow.
    func waitForItems(_ count: Int, timeout: TimeInterval = 30) async -> [Int] {
        let deadline = Date().addingTimeInterval(timeout)
        while processedItems.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return processedItems
    }
}

// MARK: - Tests

@Suite(.tags(.concurrency))
struct TaskObserveTests {
    @Test func streamProcessesAllElements() async {
        let observer = TestObserver()
        let stream = AsyncStream<Int> { continuation in
            for i in 1 ... 5 {
                continuation.yield(i)
            }
            continuation.finish()
        }

        _ = stream.subscribe(observer) { observer, element in
            await observer.recordItem(element)
        }

        let items = await observer.waitForItems(5)
        #expect(items == [1, 2, 3, 4, 5])
    }

    @Test func streamBreaksWhenObserverDeallocates() async throws {
        var observer: TestObserver? = TestObserver(id: "dealloc-test")
        weak var weakObserver = observer

        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)

        _ = try stream.subscribe(#require(observer)) { observer, element in
            await observer.recordItem(element)
        }

        continuation.yield(1)
        continuation.yield(2)

        let itemsBeforeDealloc = await observer?.waitForItems(2)
        #expect(itemsBeforeDealloc == [1, 2])

        observer = nil

        // The subscription holds the observer weakly, but its task may still be mid-element; poll
        // rather than assume the drop lands inside a fixed window. Inline rather than via `poll`,
        // because a `weak var` local cannot cross into a `@Sendable` closure.
        let deallocDeadline = Date().addingTimeInterval(5)
        while weakObserver != nil, Date() < deallocDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(weakObserver == nil, "Observer should have been deallocated")
        weakObserver = nil

        continuation.yield(3)
        continuation.yield(4)
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    @Test func streamCancellation() async throws {
        let observer = TestObserver()
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)

        let task = stream.subscribe(observer) { observer, element in
            await observer.recordItem(element)
        }

        continuation.yield(1)

        let itemsBeforeCancel = await observer.waitForItems(1)
        #expect(itemsBeforeCancel == [1])

        task.cancel()

        continuation.yield(2)
        try await Task.sleep(nanoseconds: 50_000_000)

        let itemsAfterCancel = await observer.processedItems
        #expect(itemsAfterCancel.count <= 2)
    }

    @Test func streamFinishEndsTask() async {
        let observer = TestObserver()
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)

        _ = stream.subscribe(observer) { observer, element in
            await observer.recordItem(element)
        }

        continuation.yield(1)
        continuation.yield(2)
        continuation.finish()

        let items = await observer.waitForItems(2)
        #expect(items == [1, 2])
    }
}
