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

/// Tests for the Stopwatch utility type.
class StopwatchTests: LKTestCase {
    func testStopwatchInitialization() {
        let sw = Stopwatch(label: "test")
        XCTAssertEqual(sw.label, "test")
        XCTAssertTrue(sw.splits.isEmpty)
        XCTAssertTrue(sw.start > 0)
    }

    func testTotalWithNoSplitsReturnsZero() {
        let sw = Stopwatch(label: "empty")
        XCTAssertEqual(sw.total(), 0)
    }

    func testSplitAddsEntry() {
        var sw = Stopwatch(label: "test")
        sw.split(label: "first")
        XCTAssertEqual(sw.splits.count, 1)
        XCTAssertEqual(sw.splits[0].label, "first")
    }

    func testMultipleSplits() {
        var sw = Stopwatch(label: "test")
        sw.split(label: "a")
        sw.split(label: "b")
        sw.split(label: "c")
        XCTAssertEqual(sw.splits.count, 3)
    }

    func testTotalIsNonNegative() {
        var sw = Stopwatch(label: "test")
        sw.split(label: "end")
        XCTAssertTrue(sw.total() >= 0)
    }

    func testEquality() {
        let sw1 = Stopwatch(label: "test")
        let sw2 = sw1 // Copy (value type)
        XCTAssertEqual(sw1, sw2)
    }

    func testInequalityAfterSplit() {
        var sw1 = Stopwatch(label: "test")
        let sw2 = sw1
        sw1.split(label: "modified")
        XCTAssertNotEqual(sw1, sw2)
    }

    func testDescription() {
        var sw = Stopwatch(label: "connect")
        sw.split(label: "ws")
        let desc = sw.description
        XCTAssertTrue(desc.contains("Stopwatch(connect"))
        XCTAssertTrue(desc.contains("ws"))
        XCTAssertTrue(desc.contains("total"))
    }

    func testEntryEquality() {
        let a = Stopwatch.Entry(label: "test", time: 100.0)
        let b = Stopwatch.Entry(label: "test", time: 100.0)
        XCTAssertEqual(a, b)

        let c = Stopwatch.Entry(label: "other", time: 100.0)
        XCTAssertNotEqual(a, c)
    }
}
