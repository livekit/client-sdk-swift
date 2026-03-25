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

class RingBufferTests: LKTestCase {
    // MARK: - Init

    func testInitCreatesZeroFilledBuffer() {
        let buffer = RingBuffer<Int>(size: 4)

        // Buffer not full yet, read returns nil
        XCTAssertNil(buffer.read())
    }

    // MARK: - Write Single Values

    func testWriteBeforeFullReturnsNil() {
        let buffer = RingBuffer<Int>(size: 4)
        buffer.write(1)
        buffer.write(2)
        buffer.write(3)

        XCTAssertNil(buffer.read(), "Should return nil before buffer is full")
    }

    func testWriteExactlyFillsBuffer() {
        let buffer = RingBuffer<Int>(size: 4)
        buffer.write(10)
        buffer.write(20)
        buffer.write(30)
        buffer.write(40)

        let result = buffer.read()
        XCTAssertEqual(result, [10, 20, 30, 40])
    }

    func testWriteWrapsAroundBuffer() {
        let buffer = RingBuffer<Int>(size: 3)
        buffer.write(1)
        buffer.write(2)
        buffer.write(3) // Buffer now full, head at 0

        // Write one more — overwrites index 0
        buffer.write(4) // head now at 1

        let result = buffer.read()
        XCTAssertEqual(result, [2, 3, 4])
    }

    func testWriteMultipleWraps() {
        let buffer = RingBuffer<Int>(size: 3)
        // Fill 7 values into size-3 buffer
        for i in 1 ... 7 {
            buffer.write(i)
        }

        let result = buffer.read()
        XCTAssertEqual(result, [5, 6, 7])
    }

    // MARK: - Write Sequence

    func testWriteSequenceFillsBuffer() {
        let buffer = RingBuffer<Int>(size: 4)
        buffer.write([10, 20, 30, 40])

        let result = buffer.read()
        XCTAssertEqual(result, [10, 20, 30, 40])
    }

    func testWriteSequenceWraps() {
        let buffer = RingBuffer<Int>(size: 3)
        buffer.write([1, 2, 3, 4, 5])

        let result = buffer.read()
        XCTAssertEqual(result, [3, 4, 5])
    }

    func testWriteSequencePartialThenFull() {
        let buffer = RingBuffer<Int>(size: 4)
        buffer.write([1, 2])
        XCTAssertNil(buffer.read())

        buffer.write([3, 4])
        let result = buffer.read()
        XCTAssertEqual(result, [1, 2, 3, 4])
    }

    // MARK: - Read Order

    func testReadReturnsCorrectOrderAfterWrap() {
        let buffer = RingBuffer<Int>(size: 5)
        // Write 8 values into size-5 buffer
        for i in 1 ... 8 {
            buffer.write(i)
        }

        let result = buffer.read()
        // Should return the last 5 values in order
        XCTAssertEqual(result, [4, 5, 6, 7, 8])
    }

    func testReadWhenHeadAtZeroReturnsEntireBuffer() {
        let buffer = RingBuffer<Int>(size: 3)
        // Write exactly one full cycle + another full cycle
        buffer.write([1, 2, 3])
        buffer.write([4, 5, 6]) // head back at 0

        let result = buffer.read()
        XCTAssertEqual(result, [4, 5, 6])
    }

    // MARK: - Float Type

    func testWorksWithFloats() {
        let buffer = RingBuffer<Float>(size: 3)
        buffer.write([0.1, 0.5, 0.9])

        let result = buffer.read()
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.count, 3)
        XCTAssertEqual(result![0], 0.1, accuracy: 0.001)
        XCTAssertEqual(result![1], 0.5, accuracy: 0.001)
        XCTAssertEqual(result![2], 0.9, accuracy: 0.001)
    }

    // MARK: - Size 1

    func testSizeOneBuffer() {
        let buffer = RingBuffer<Int>(size: 1)
        buffer.write(42)

        let result = buffer.read()
        XCTAssertEqual(result, [42])

        buffer.write(99)
        let result2 = buffer.read()
        XCTAssertEqual(result2, [99])
    }
}
