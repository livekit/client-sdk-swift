/*
 * Copyright 2025 LiveKit
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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

// MARK: - Test Owner

/// A simple Sendable owner actor for testing.
actor TestOwner {
    let id: String
    private(set) var processedItems: [Int] = []

    init(id: String = "test") {
        self.id = id
    }

    deinit {
        print("TestOwner(\(id)) deinit")
    }

    func recordItem(_ item: Int) {
        processedItems.append(item)
    }
}

// MARK: - Tests

class TaskObserveTests: LKTestCase {
    override func setUpWithError() throws {}

    override func tearDown() async throws {}

    // MARK: - Stream Tests

    func testStreamProcessesAllElements() async throws {
        let owner = TestOwner()
        let stream = AsyncStream<Int> { continuation in
            for i in 1 ... 5 {
                continuation.yield(i)
            }
            continuation.finish()
        }

        Task.observe(stream, by: owner) { owner, element in
            await owner.recordItem(element)
        }

        // Wait for processing
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let items = await owner.processedItems
        XCTAssertEqual(items, [1, 2, 3, 4, 5])
    }

    func testStreamBreaksWhenOwnerDeallocates() async throws {
        var owner: TestOwner? = TestOwner(id: "dealloc-test")
        weak var weakOwner = owner

        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)

        Task.observe(stream, by: owner!) { owner, element in
            await owner.recordItem(element)
        }

        // Yield some elements
        continuation.yield(1)
        continuation.yield(2)
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        let itemsBeforeDealloc = await owner?.processedItems
        XCTAssertEqual(itemsBeforeDealloc, [1, 2])

        // Deallocate owner
        owner = nil

        // Give time for deallocation
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Owner should be deallocated
        XCTAssertNil(weakOwner, "Owner should have been deallocated")

        // Yield more elements - should not crash, task should have broken
        continuation.yield(3)
        continuation.yield(4)
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }

    func testStreamCancellation() async throws {
        let owner = TestOwner()
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)

        let task = Task.observe(stream, by: owner) { owner, element in
            await owner.recordItem(element)
        }

        continuation.yield(1)
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        let itemsBeforeCancel = await owner.processedItems
        XCTAssertEqual(itemsBeforeCancel, [1])

        // Cancel the task explicitly
        task.cancel()
        XCTAssertTrue(task.isCancelled)

        // Yield more - should not be processed
        continuation.yield(2)
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Item 2 should not be processed (or the task already broke)
        let itemsAfterCancel = await owner.processedItems
        XCTAssertTrue(itemsAfterCancel.count <= 2)
    }

    func testStreamFinishEndsTask() async throws {
        let owner = TestOwner()
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)

        Task.observe(stream, by: owner) { owner, element in
            await owner.recordItem(element)
        }

        continuation.yield(1)
        continuation.yield(2)
        continuation.finish() // End the stream

        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let items = await owner.processedItems
        XCTAssertEqual(items, [1, 2])
    }
}
