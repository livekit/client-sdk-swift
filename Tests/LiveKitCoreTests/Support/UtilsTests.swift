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

class UtilsTests: LKTestCase {
    // MARK: - computeAttributesDiff

    func testAttributesDiffWithAddedKey() {
        let old = ["a": "1"]
        let new: [String: String] = ["a": "1", "b": "2"]

        let diff = computeAttributesDiff(oldValues: old, newValues: new)

        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff["b"], "2")
    }

    func testAttributesDiffWithRemovedKey() {
        let old: [String: String] = ["a": "1", "b": "2"]
        let new = ["a": "1"]

        let diff = computeAttributesDiff(oldValues: old, newValues: new)

        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff["b"], "") // removed keys get empty string
    }

    func testAttributesDiffWithChangedValue() {
        let old = ["a": "1"]
        let new = ["a": "2"]

        let diff = computeAttributesDiff(oldValues: old, newValues: new)

        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff["a"], "2")
    }

    func testAttributesDiffNoChanges() {
        let old: [String: String] = ["a": "1", "b": "2"]
        let new: [String: String] = ["a": "1", "b": "2"]

        let diff = computeAttributesDiff(oldValues: old, newValues: new)

        XCTAssertTrue(diff.isEmpty)
    }

    func testAttributesDiffBothEmpty() {
        let diff = computeAttributesDiff(oldValues: [:], newValues: [:])
        XCTAssertTrue(diff.isEmpty)
    }

    func testAttributesDiffMultipleChanges() {
        let old: [String: String] = ["a": "1", "b": "2", "c": "3"]
        let new: [String: String] = ["a": "changed", "c": "3", "d": "new"]

        let diff = computeAttributesDiff(oldValues: old, newValues: new)

        XCTAssertEqual(diff.count, 3)
        XCTAssertEqual(diff["a"], "changed")
        XCTAssertEqual(diff["b"], "") // removed
        XCTAssertEqual(diff["d"], "new")
    }
}
