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

/// Tests for MapTable — a thin Sendable wrapper around NSMapTable.
class MapTableTests: LKTestCase {
    func testWeakToStrongObjectsCreation() {
        let table = MapTable<NSString, NSNumber>.weakToStrongObjects()
        XCTAssertEqual(table.count, 0)
    }

    func testSetAndGetObject() {
        let table = MapTable<NSString, NSNumber>.weakToStrongObjects()
        let key: NSString = "key1"
        let value = NSNumber(value: 42)
        table.setObject(value, forKey: key)
        XCTAssertEqual(table.object(forKey: key), value)
        XCTAssertEqual(table.count, 1)
    }

    func testRemoveObject() {
        let table = MapTable<NSString, NSNumber>.weakToStrongObjects()
        let key: NSString = "key1"
        table.setObject(NSNumber(value: 1), forKey: key)
        XCTAssertEqual(table.count, 1)
        table.removeObject(forKey: key)
        XCTAssertNil(table.object(forKey: key))
    }

    func testRemoveAllObjects() {
        let table = MapTable<NSString, NSNumber>.weakToStrongObjects()
        table.setObject(NSNumber(value: 1), forKey: "a")
        table.setObject(NSNumber(value: 2), forKey: "b")
        XCTAssertEqual(table.count, 2)
        table.removeAllObjects()
        XCTAssertEqual(table.count, 0)
    }

    func testObjectForNilKey() {
        let table = MapTable<NSString, NSNumber>.weakToStrongObjects()
        XCTAssertNil(table.object(forKey: nil))
    }

    func testObjectEnumerator() {
        let table = MapTable<NSString, NSNumber>.weakToStrongObjects()
        table.setObject(NSNumber(value: 10), forKey: "x")
        table.setObject(NSNumber(value: 20), forKey: "y")
        let enumerator = table.objectEnumerator()
        XCTAssertNotNil(enumerator)
        var values = [Int]()
        while let obj = enumerator?.nextObject() as? NSNumber {
            values.append(obj.intValue)
        }
        XCTAssertEqual(values.sorted(), [10, 20])
    }
}
