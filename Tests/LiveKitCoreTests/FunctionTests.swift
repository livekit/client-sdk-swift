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

class FunctionTests: LKTestCase {
    func testRangeMerge() async throws {
        let range1 = 10 ... 20
        let range2 = 5 ... 15

        let merged = merge(range: range1, with: range2)
        print("merged: \(merged)")
        XCTAssert(merged == 5 ... 20)
    }

    func testAttributesUpdated() {
        let oldValues: [String: String] = ["a": "value", "b": "initial", "c": "value"]
        let newValues: [String: String] = ["a": "value", "b": "updated", "c": "value"]

        let diff = computeAttributesDiff(oldValues: oldValues, newValues: newValues)
        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff["b"], "updated")
    }

    func testAttributesNew() {
        let newValues: [String: String] = ["a": "value", "b": "value", "c": "value"]
        let oldValues: [String: String] = ["a": "value", "b": "value"]

        let diff = computeAttributesDiff(oldValues: oldValues, newValues: newValues)
        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff["c"], "value")
    }

    func testAttributesRemoved() {
        let newValues: [String: String] = ["a": "value", "b": "value"]
        let oldValues: [String: String] = ["a": "value", "b": "value", "c": "value"]

        let diff = computeAttributesDiff(oldValues: oldValues, newValues: newValues)
        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff["c"], "")
    }
}
