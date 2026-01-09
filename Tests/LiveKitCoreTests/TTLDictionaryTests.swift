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

// swiftformat:disable preferForLoop
class TTLDictionaryTests: LKTestCase {
    private let shortTTL: TimeInterval = 0.1
    private var dictionary: TTLDictionary<String, String>!

    override func setUp() {
        super.setUp()
        dictionary = TTLDictionary<String, String>(ttl: shortTTL)
    }

    func testExpiration() async throws {
        dictionary["key1"] = "value1"
        dictionary["key2"] = "value2"
        dictionary["key3"] = "value3"

        XCTAssertNotNil(dictionary["key1"])
        XCTAssertNotNil(dictionary["key2"])
        XCTAssertNotNil(dictionary["key3"])

        try await Task.sleep(nanoseconds: UInt64(2 * shortTTL * 1_000_000_000))

        XCTAssertNil(dictionary["key1"])
        XCTAssertNil(dictionary["key2"])
        XCTAssertNil(dictionary["key3"])

        XCTAssertEqual(dictionary.count, 0)
        XCTAssertTrue(dictionary.keys.isEmpty)
        XCTAssertTrue(dictionary.values.isEmpty)

        dictionary.forEach { _, _ in XCTFail("Dictionary should be empty") }
        _ = dictionary.map { _, _ in XCTFail("Dictionary should be empty") }
    }
}
