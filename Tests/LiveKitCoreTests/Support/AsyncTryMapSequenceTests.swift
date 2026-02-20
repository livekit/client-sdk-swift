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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Tests for the AsyncTryMapSequence extension on AsyncSequence.
class AsyncTryMapSequenceTests: LKTestCase {
    func testTryMapTransformsElements() async throws {
        let source = AsyncStream<Int> { continuation in
            continuation.yield(1)
            continuation.yield(2)
            continuation.yield(3)
            continuation.finish()
        }

        let mapped = source.tryMap { $0 * 2 }
        var results = [Int]()
        for try await value in mapped {
            results.append(value)
        }
        XCTAssertEqual(results, [2, 4, 6])
    }

    func testTryMapPropagatesError() async {
        struct TestError: Error {}

        let source = AsyncStream<Int> { continuation in
            continuation.yield(1)
            continuation.yield(2)
            continuation.finish()
        }

        let mapped = source.tryMap { (value: Int) -> Int in
            if value == 2 { throw TestError() }
            return value
        }

        var results = [Int]()
        do {
            for try await value in mapped {
                results.append(value)
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is TestError)
        }
        XCTAssertEqual(results, [1])
    }

    func testTryMapWithEmptySequence() async throws {
        let source = AsyncStream<Int> { $0.finish() }
        let mapped = source.tryMap { $0 * 2 }
        var results = [Int]()
        for try await value in mapped {
            results.append(value)
        }
        XCTAssertTrue(results.isEmpty)
    }
}
