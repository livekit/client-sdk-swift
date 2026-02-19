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
    @Test func byteLength() {
        // ASCII characters (1 byte each)
        #expect("hello".byteLength == 5)
        #expect("".byteLength == 0)

        // Unicode characters (variable bytes)
        #expect("👋".byteLength == 4) // Emoji (4 bytes)
        #expect("ñ".byteLength == 2) // Spanish n with tilde (2 bytes)
        #expect("你好".byteLength == 6) // Chinese characters (3 bytes each)
    }

    @Test func truncate() {
        // Test ASCII strings
        #expect("hello".truncate(maxBytes: 5) == "hello")
        #expect("hello".truncate(maxBytes: 3) == "hel")
        #expect("".truncate(maxBytes: 5) == "")

        // Test Unicode strings
        #expect("👋hello".truncate(maxBytes: 4) == "👋") // Emoji is 4 bytes
        #expect("hi👋".truncate(maxBytes: 5) == "hi") // Won't cut in middle of emoji
        #expect("你好world".truncate(maxBytes: 6) == "你好") // Chinese characters are 3 bytes each

        // Test edge cases
        #expect("hello".truncate(maxBytes: 0) == "")
        #expect("hello".truncate(maxBytes: 100) == "hello")
    }
}
