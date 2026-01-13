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

class OutgoingStreamManagerTests: LKTestCase {
    func testStreamBytes() async throws {
        let headerExpectation = expectation(description: "Produces header packet")
        let chunkExpectation = expectation(description: "Produces chunk packets")
        let trailerExpectation = expectation(description: "Produces trailer packet")

        let testChunks = [
            Data(repeating: 0xAB, count: 128),
            Data(repeating: 0xCD, count: 128),
            Data(repeating: 0xEF, count: 256),
            Data(repeating: 0x12, count: 32),
        ]
        let streamID = UUID().uuidString
        let topic = "some-topic"

        let counter = ConcurrentCounter()

        let manager = OutgoingStreamManager { packet in
            // Simulate data channel send
            try await Task.sleep(nanoseconds: 10_000_000)

            switch packet.value {
            case let .streamHeader(header):
                XCTAssertEqual(header.streamID, streamID)
                XCTAssertEqual(header.topic, topic)
                XCTAssertEqual(header.mimeType, "application/octet-stream")

                headerExpectation.fulfill()

            case let .streamChunk(chunk):
                let currentChunk = await counter.increment()
                XCTAssertEqual(chunk.streamID, streamID)
                XCTAssertEqual(chunk.chunkIndex, UInt64(currentChunk))
                XCTAssertEqual(chunk.content, testChunks[currentChunk])

                if await counter.getCount() == testChunks.count {
                    chunkExpectation.fulfill()
                }

            case let .streamTrailer(trailer):
                XCTAssertEqual(trailer.streamID, streamID)
                XCTAssertEqual(trailer.reason, "")

                trailerExpectation.fulfill()

            default: XCTFail("Produced unexpected packet type")
            }
        } encryptionProvider: {
            .none
        }

        let writer = try await manager.streamBytes(
            options: StreamByteOptions(topic: topic, id: streamID)
        )

        for chunk in testChunks {
            try await writer.write(chunk)
        }
        try await writer.close()

        await fulfillment(
            of: [headerExpectation, chunkExpectation, trailerExpectation],
            timeout: 5,
            enforceOrder: true
        )
    }

    func testStreamText() async throws {
        let headerExpectation = expectation(description: "Produces header packet")
        let chunkExpectation = expectation(description: "Produces chunk packets")
        let trailerExpectation = expectation(description: "Produces trailer packet")

        let testChunks = [
            String(repeating: "A", count: 128),
            String(repeating: "B", count: 128),
            String(repeating: "C", count: 256),
            String(repeating: "D", count: 32),
        ]
        let streamID = UUID().uuidString
        let topic = "some-topic"

        let counter = ConcurrentCounter()

        let manager = OutgoingStreamManager { packet in
            // Simulate data channel send
            try await Task.sleep(nanoseconds: 10_000_000)

            switch packet.value {
            case let .streamHeader(header):
                XCTAssertEqual(header.streamID, streamID)
                XCTAssertEqual(header.topic, topic)
                XCTAssertEqual(header.mimeType, "text/plain")

                headerExpectation.fulfill()

            case let .streamChunk(chunk):
                let currentChunk = await counter.increment()
                XCTAssertEqual(chunk.streamID, streamID)
                XCTAssertEqual(chunk.chunkIndex, UInt64(currentChunk))
                XCTAssertEqual(chunk.content, Data(testChunks[currentChunk].utf8))

                if await counter.getCount() == testChunks.count {
                    chunkExpectation.fulfill()
                }

            case let .streamTrailer(trailer):
                XCTAssertEqual(trailer.streamID, streamID)
                XCTAssertEqual(trailer.reason, "")

                trailerExpectation.fulfill()

            default: XCTFail("Produced unexpected packet type")
            }
        } encryptionProvider: {
            .none
        }

        let writer = try await manager.streamText(
            options: StreamTextOptions(topic: topic, id: streamID)
        )

        for chunk in testChunks {
            try await writer.write(chunk)
        }
        try await writer.close()

        await fulfillment(
            of: [headerExpectation, chunkExpectation, trailerExpectation],
            timeout: 5,
            enforceOrder: true
        )
    }

    func testErrorPropagation() async throws {
        let errorExpectation = expectation(description: "Error propagates to caller")

        let testError = LiveKitError(.cancelled, message: "Test error")

        let manager = OutgoingStreamManager { packet in
            switch packet.value {
            case .streamChunk:
                // Wait until first chunk to produce error
                throw testError
            default: break
            }
        } encryptionProvider: {
            .none
        }

        let writer = try await manager.streamText(
            options: StreamTextOptions(topic: "some-topic")
        )
        do {
            try await writer.write("Hello, world!")
        } catch {
            XCTAssertEqual(error as? LiveKitError, testError)
            errorExpectation.fulfill()
        }

        await fulfillment(
            of: [errorExpectation],
            timeout: 5
        )
    }
}
