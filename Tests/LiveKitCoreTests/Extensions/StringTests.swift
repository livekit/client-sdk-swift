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

struct StringTests {
    @Test(arguments: [
        ("hello", 5),
        ("", 0),
        ("\u{1F44B}", 4), // 👋 emoji (4 bytes)
        ("\u{00F1}", 2), // ñ (2 bytes)
        ("\u{4F60}\u{597D}", 6), // 你好 (3 bytes each)
    ])
    func byteLength(input: String, expected: Int) {
        #expect(input.byteLength == expected)
    }

    @Test func truncate() {
        // ASCII strings
        #expect("hello".truncate(maxBytes: 5) == "hello")
        #expect("hello".truncate(maxBytes: 3) == "hel")
        #expect("".truncate(maxBytes: 5) == "")

        // Unicode strings
        #expect("👋hello".truncate(maxBytes: 4) == "👋") // Emoji is 4 bytes
        #expect("hi👋".truncate(maxBytes: 5) == "hi") // Won't cut in middle of emoji
        #expect("你好world".truncate(maxBytes: 6) == "你好") // Chinese characters are 3 bytes each

        // Edge cases
        #expect("hello".truncate(maxBytes: 0) == "")
        #expect("hello".truncate(maxBytes: 100) == "hello")
    }
}
