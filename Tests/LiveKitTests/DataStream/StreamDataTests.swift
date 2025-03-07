/*
 * Copyright 2025 LiveKit
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
import XCTest

class StreamDataTests: LKTestCase {
    // MARK: - Data chunking

    func testDataChunking() {
        let testData = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])

        let chunks = testData.chunks(of: 3)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks[0].dataRepresentation, Data([1, 2, 3]))
        XCTAssertEqual(chunks[1].dataRepresentation, Data([4, 5, 6]))
        XCTAssertEqual(chunks[2].dataRepresentation, Data([7, 8, 9]))
        XCTAssertEqual(chunks[3].dataRepresentation, Data([10]))

        let fullChunk = testData.chunks(of: 10)
        XCTAssertEqual(fullChunk.count, 1)
        XCTAssertEqual(fullChunk[0].dataRepresentation, testData)

        let largeChunk = testData.chunks(of: 20)
        XCTAssertEqual(largeChunk.count, 1)
        XCTAssertEqual(largeChunk[0].dataRepresentation, testData)
    }

    func testEmptyDataChunking() {
        let emptyData = Data()
        XCTAssertTrue(emptyData.chunks(of: 5).isEmpty)
    }

    func testSingleByteDataChunking() {
        let singleByteData = Data([42])

        let chunks = singleByteData.chunks(of: 1)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].dataRepresentation, singleByteData)
    }

    func testInvalidChunkSize() {
        let testData = Data([1, 2, 3, 4, 5])

        // Zero or negative chunk size should return empty array
        XCTAssertTrue(testData.chunks(of: 0).isEmpty)
        XCTAssertTrue(testData.chunks(of: -1).isEmpty)
    }

    // MARK: - String chunking

    func testStringChunking() {
        let testString = "Hello, World!"
        let chunks = testString.chunks(of: 4)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks[0], "Hell")
        XCTAssertEqual(chunks[1], "o, W")
        XCTAssertEqual(chunks[2], "orld")
        XCTAssertEqual(chunks[3], "!")
    }

    func testEmptyStringChunking() {
        let emptyString = ""
        XCTAssertTrue(emptyString.chunks(of: 5).isEmpty)
    }

    func testSingleCharacterStringChunking() {
        let singleCharString = "X"
        let chunks = singleCharString.chunks(of: 1)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(String(chunks[0]), singleCharString)
    }

    // MARK: - UTF-8 edge cases

    func testMixedStringChunking() {
        let mixedString = "Hello 👋 World!"
        let chunks = mixedString.chunks(of: 6)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0], "Hello ")
        XCTAssertEqual(chunks[1], "👋 Worl")
        XCTAssertEqual(chunks[2], "d!")
    }

    func testComplexUnicodeSequenceChunking() {
        // String with combining characters, which should be considered single grapheme clusters
        let complexString = "e\u{301}" // é (e + combining acute accent)
        let chunks = complexString.chunks(of: 1)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], "é")
    }

    func testSurrogatePairsChunking() {
        // Test with characters represented by surrogate pairs in UTF-16
        let surrogatePairString = "𐐷" // U+10437, requires surrogate pair in UTF-16
        let chunks = surrogatePairString.chunks(of: 1)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], "𐐷")
    }

    // MARK: - Data representation

    func testDataRepresentation() {
        let data = Data([1, 2, 3, 4, 5])
        XCTAssertEqual(data.dataRepresentation, data)

        let string = "Hello, World!"
        XCTAssertEqual(Substring(string).dataRepresentation, Data(string.utf8))
    }
}
