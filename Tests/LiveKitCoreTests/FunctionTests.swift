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

struct FunctionTests {
    @Test func rangeMerge() {
        let range1 = 10 ... 20
        let range2 = 5 ... 15

        let merged = merge(range: range1, with: range2)
        print("merged: \(merged)")
        #expect(merged == 5 ... 20)
    }

    @Test func attributesUpdated() {
        let oldValues: [String: String] = ["a": "value", "b": "initial", "c": "value"]
        let newValues: [String: String] = ["a": "value", "b": "updated", "c": "value"]

        let diff = computeAttributesDiff(oldValues: oldValues, newValues: newValues)
        #expect(diff.count == 1)
        #expect(diff["b"] == "updated")
    }

    @Test func attributesNew() {
        let newValues: [String: String] = ["a": "value", "b": "value", "c": "value"]
        let oldValues: [String: String] = ["a": "value", "b": "value"]

        let diff = computeAttributesDiff(oldValues: oldValues, newValues: newValues)
        #expect(diff.count == 1)
        #expect(diff["c"] == "value")
    }

    @Test func attributesRemoved() {
        let newValues: [String: String] = ["a": "value", "b": "value"]
        let oldValues: [String: String] = ["a": "value", "b": "value", "c": "value"]

        let diff = computeAttributesDiff(oldValues: oldValues, newValues: newValues)
        #expect(diff.count == 1)
        #expect(diff["c"] == "")
    }
}
