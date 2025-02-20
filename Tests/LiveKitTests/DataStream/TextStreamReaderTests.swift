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

class TextStreamReaderTests: XCTestCase {
    private var continuation: StreamReaderSource.Continuation!
    private var reader: TextStreamReader!
    
    private let testChunks = [
        "First chunk",
        "Second chunk",
        "Third chunk",
        "Forth chunk",
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
        let source = AsyncThrowingStream {
            self.continuation = $0
        }
        let info = TextStreamInfo(
            id: UUID().uuidString,
            mimeType: "text/plain",
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
        reader = TextStreamReader(info: info, source: source)
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
    
    func testChunkReadCallback() async {
        let receiveExpectation = expectation(description: "Receive all chunks")
        let closureExpectation = expectation(description: "Normal closure")
        
        var chunkIndex = 0
        
        reader.readChunks { chunk in
            XCTAssertEqual(chunk, self.testChunks[chunkIndex])
            if chunkIndex == self.testChunks.count - 1 {
                receiveExpectation.fulfill()
            }
            chunkIndex += 1
        } onCompletion: { error in
            XCTAssertNil(error)
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
