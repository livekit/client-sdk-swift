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

// swiftformat:disable preferForLoop
struct TTLDictionaryTests {
    private let shortTTL: TimeInterval = 0.1
    private var dictionary: TTLDictionary<String, String>

    init() {
        dictionary = TTLDictionary<String, String>(ttl: shortTTL)
    }

    @Test mutating func expiration() async throws {
        dictionary["key1"] = "value1"
        dictionary["key2"] = "value2"
        dictionary["key3"] = "value3"

        #expect(dictionary["key1"] != nil)
        #expect(dictionary["key2"] != nil)
        #expect(dictionary["key3"] != nil)

        try await Task.sleep(nanoseconds: UInt64(2 * shortTTL * 1_000_000_000))

        #expect(dictionary["key1"] == nil)
        #expect(dictionary["key2"] == nil)
        #expect(dictionary["key3"] == nil)

        #expect(dictionary.count == 0)
        #expect(dictionary.keys.isEmpty)
        #expect(dictionary.values.isEmpty)

        dictionary.forEach { _, _ in Issue.record("Dictionary should be empty") }
        _ = dictionary.map { _, _ in Issue.record("Dictionary should be empty") }
    }
}
