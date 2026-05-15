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

@Suite(.tags(.dataStream))
struct StreamDataTests {
    // MARK: - Data chunking

    @Test func dataChunking() {
        let testData = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])

        let chunks = testData.chunks(of: 3)
        #expect(chunks.count == 4)
        #expect(chunks[0] == Data([1, 2, 3]))
        #expect(chunks[1] == Data([4, 5, 6]))
        #expect(chunks[2] == Data([7, 8, 9]))
        #expect(chunks[3] == Data([10]))

        let fullChunk = testData.chunks(of: 10)
        #expect(fullChunk.count == 1)
        #expect(fullChunk[0] == testData)

        let largeChunk = testData.chunks(of: 20)
        #expect(largeChunk.count == 1)
        #expect(largeChunk[0] == testData)
    }

    @Test func emptyDataChunking() {
        #expect(Data().chunks(of: 5).isEmpty)
    }

    @Test func singleByteDataChunking() {
        let singleByteData = Data([42])
        let chunks = singleByteData.chunks(of: 1)
        #expect(chunks == [singleByteData])
    }

    @Test func dataInvalidChunkSize() {
        let testData = Data([1, 2, 3, 4, 5])
        #expect(testData.chunks(of: 0).isEmpty)
        #expect(testData.chunks(of: -1).isEmpty)
    }

    // MARK: - String chunking

    @Test func stringChunking() {
        let testString = "Hello, World!"
        let chunks = testString.chunks(of: 4)
            .map { [UInt8]($0) }
        #expect(chunks == [[72, 101, 108, 108], [111, 44, 32, 87], [111, 114, 108, 100], [33]])
    }

    @Test func emptyStringChunking() {
        #expect("".chunks(of: 5).isEmpty)
    }

    @Test func singleCharacterStringChunking() {
        #expect("X".chunks(of: 5).map { [UInt8]($0) } == [[88]])
    }

    @Test func mixedStringChunking() {
        let mixedString = "Hello \u{1F44B}"
        let chunks = mixedString.chunks(of: 4)
            .map { [UInt8]($0) }
        #expect(chunks == [[0x48, 0x65, 0x6C, 0x6C], [0x6F, 0x20], [0xF0, 0x9F, 0x91, 0x8B]])
    }
}
