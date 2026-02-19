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
}

// MARK: - Tests

struct TaskObserveTests {
    @Test func streamProcessesAllElements() async throws {
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

        try await Task.sleep(nanoseconds: 100_000_000)

        let items = await observer.processedItems
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
        try await Task.sleep(nanoseconds: 50_000_000)

        let itemsBeforeDealloc = await observer?.processedItems
        #expect(itemsBeforeDealloc == [1, 2])

        observer = nil

        try await Task.sleep(nanoseconds: 50_000_000)

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
        try await Task.sleep(nanoseconds: 50_000_000)

        let itemsBeforeCancel = await observer.processedItems
        #expect(itemsBeforeCancel == [1])

        task.cancel()

        continuation.yield(2)
        try await Task.sleep(nanoseconds: 50_000_000)

        let itemsAfterCancel = await observer.processedItems
        #expect(itemsAfterCancel.count <= 2)
    }

    @Test func streamFinishEndsTask() async throws {
        let observer = TestObserver()
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)

        _ = stream.subscribe(observer) { observer, element in
            await observer.recordItem(element)
        }

        continuation.yield(1)
        continuation.yield(2)
        continuation.finish()

        try await Task.sleep(nanoseconds: 100_000_000)

        let items = await observer.processedItems
        #expect(items == [1, 2])
    }
}
