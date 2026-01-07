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

class StreamDataTests: LKTestCase {
    // MARK: - Data chunking

    func testDataChunking() {
        let testData = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])

        let chunks = testData.chunks(of: 3)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks[0], Data([1, 2, 3]))
        XCTAssertEqual(chunks[1], Data([4, 5, 6]))
        XCTAssertEqual(chunks[2], Data([7, 8, 9]))
        XCTAssertEqual(chunks[3], Data([10]))

        let fullChunk = testData.chunks(of: 10)
        XCTAssertEqual(fullChunk.count, 1)
        XCTAssertEqual(fullChunk[0], testData)

        let largeChunk = testData.chunks(of: 20)
        XCTAssertEqual(largeChunk.count, 1)
        XCTAssertEqual(largeChunk[0], testData)
    }

    func testEmptyDataChunking() {
        XCTAssertTrue(Data().chunks(of: 5).isEmpty)
    }

    func testSingleByteDataChunking() {
        let singleByteData = Data([42])
        let chunks = singleByteData.chunks(of: 1)
        XCTAssertEqual(chunks, [singleByteData])
    }

    func testDataInvalidChunkSize() {
        let testData = Data([1, 2, 3, 4, 5])
        XCTAssertTrue(testData.chunks(of: 0).isEmpty)
        XCTAssertTrue(testData.chunks(of: -1).isEmpty)
    }

    // MARK: - String chunking

    func testStringChunking() {
        let testString = "Hello, World!"
        let chunks = testString.chunks(of: 4)
            .map { [UInt8]($0) }
        XCTAssertEqual(chunks, [[72, 101, 108, 108], [111, 44, 32, 87], [111, 114, 108, 100], [33]])
    }

    func testEmptyStringChunking() {
        XCTAssertTrue("".chunks(of: 5).isEmpty)
    }

    func testSingleCharacterStringChunking() {
        XCTAssertEqual("X".chunks(of: 5).map { [UInt8]($0) }, [[88]])
    }

    func testMixedStringChunking() {
        let mixedString = "Hello 👋"
        let chunks = mixedString.chunks(of: 4)
            .map { [UInt8]($0) }
        XCTAssertEqual(chunks, [[0x48, 0x65, 0x6C, 0x6C], [0x6F, 0x20], [0xF0, 0x9F, 0x91, 0x8B]])
    }
}
