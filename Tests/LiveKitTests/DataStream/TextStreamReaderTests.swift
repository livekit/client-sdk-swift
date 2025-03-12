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

class TextStreamReaderTests: LKTestCase {
    private var continuation: StreamReaderSource.Continuation!
    private var reader: TextStreamReader!

    private let testInfo = TextStreamInfo(
        id: UUID().uuidString,
        topic: "someTopic",
        timestamp: Date(),
        totalLength: nil,
        attributes: [:],
        operationType: .create,
        version: 1,
        replyToStreamID: nil,
        attachedStreamIDs: [],
        generated: false
    )

    let testChunks = [
        String(repeating: "A", count: 128),
        String(repeating: "B", count: 128),
        String(repeating: "C", count: 256),
        String(repeating: "D", count: 32),
    ]

    /// All chunks combined.
    private var testPayload: String {
        testChunks.reduce("") { $0 + $1 }
    }

    private func sendPayload(closingError: Error? = nil) {
        for chunk in testChunks {
            continuation.yield(Data(chunk.utf8))
        }
        continuation.finish(throwing: closingError)
    }

    override func setUp() {
        super.setUp()
        let source = StreamReaderSource {
            self.continuation = $0
        }
        reader = TextStreamReader(info: testInfo, source: source)
    }

    func testChunkRead() async throws {
        let receiveExpectation = expectation(description: "Receive all chunks")
        let closureExpectation = expectation(description: "Normal closure")

        Task {
            var chunkIndex = 0
            for try await chunk in reader {
                XCTAssertEqual(chunk, testChunks[chunkIndex])
                if chunkIndex == testChunks.count - 1 {
                    receiveExpectation.fulfill()
                }
                chunkIndex += 1
            }
            closureExpectation.fulfill()
        }

        sendPayload()

        await fulfillment(
            of: [receiveExpectation, closureExpectation],
            timeout: 5,
            enforceOrder: true
        )
    }

    func testChunkReadError() async throws {
        let throwsExpectation = expectation(description: "Read throws error")
        let testError = StreamError.abnormalEnd(reason: "test")

        Task {
            do {
                for try await _ in reader {}
            } catch {
                XCTAssertEqual(error as? StreamError, testError)
                throwsExpectation.fulfill()
            }
        }
        sendPayload(closingError: testError)

        await fulfillment(
            of: [throwsExpectation],
            timeout: 5
        )
    }

    func testReadAll() async throws {
        let readExpectation = expectation(description: "Read full payload")

        Task {
            let fullPayload = try await reader.readAll()
            XCTAssertEqual(fullPayload, testPayload)
            readExpectation.fulfill()
        }
        sendPayload()

        await fulfillment(
            of: [readExpectation],
            timeout: 5
        )
    }
}
