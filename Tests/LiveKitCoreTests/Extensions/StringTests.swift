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

final class StringTests: LKTestCase {
    func testByteLength() {
        // ASCII characters (1 byte each)
        XCTAssertEqual("hello".byteLength, 5)
        XCTAssertEqual("".byteLength, 0)

        // Unicode characters (variable bytes)
        XCTAssertEqual("👋".byteLength, 4) // Emoji (4 bytes)
        XCTAssertEqual("ñ".byteLength, 2) // Spanish n with tilde (2 bytes)
        XCTAssertEqual("你好".byteLength, 6) // Chinese characters (3 bytes each)
    }

    func testTruncate() {
        // Test ASCII strings
        XCTAssertEqual("hello".truncate(maxBytes: 5), "hello")
        XCTAssertEqual("hello".truncate(maxBytes: 3), "hel")
        XCTAssertEqual("".truncate(maxBytes: 5), "")

        // Test Unicode strings
        XCTAssertEqual("👋hello".truncate(maxBytes: 4), "👋") // Emoji is 4 bytes
        XCTAssertEqual("hi👋".truncate(maxBytes: 5), "hi") // Won't cut in middle of emoji
        XCTAssertEqual("你好world".truncate(maxBytes: 6), "你好") // Chinese characters are 3 bytes each

        // Test edge cases
        XCTAssertEqual("hello".truncate(maxBytes: 0), "")
        XCTAssertEqual("hello".truncate(maxBytes: 100), "hello")
    }
}
