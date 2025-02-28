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

class IncomingStreamManagerTests: LKTestCase {
    private var manager: IncomingStreamManager!

    private let topicName = "someTopic"
    private let participant = Participant.Identity(from: "someName")

    override func setUp() async throws {
        manager = IncomingStreamManager()
    }

    func testRegisterByteHandler() async throws {
        try await manager.registerByteStreamHandler(for: topicName) { _, _ in }

        let throwsExpectation = expectation(description: "Throws on duplicate registration")
        do {
            try await manager.registerByteStreamHandler(for: topicName) { _, _ in }
        } catch {
            XCTAssertEqual(error as? StreamError, .handlerAlreadyRegistered)
            throwsExpectation.fulfill()
        }

        await manager.unregisterByteStreamHandler(for: topicName)

        await fulfillment(of: [throwsExpectation], timeout: 5)
    }

    func testRegisterTextHandler() async throws {
        try await manager.registerTextStreamHandler(for: topicName) { _, _ in }

        let throwsExpectation = expectation(description: "Throws on duplicate registration")
        do {
            try await manager.registerTextStreamHandler(for: topicName) { _, _ in }
        } catch {
            XCTAssertEqual(error as? StreamError, .handlerAlreadyRegistered)
            throwsExpectation.fulfill()
        }

        await manager.unregisterTextStreamHandler(for: topicName)

        await fulfillment(of: [throwsExpectation], timeout: 5)
    }

    func testByteStream() async throws {
        let receiveExpectation = expectation(description: "Receives payload")

        let testChunks = [
            Data(repeating: 0xAB, count: 128),
            Data(repeating: 0xCD, count: 128),
            Data(repeating: 0xEF, count: 256),
            Data(repeating: 0x12, count: 32),
        ]
        let testPayload = testChunks.reduce(Data()) { $0 + $1 }

        try await manager.registerByteStreamHandler(for: topicName) { reader, participant in
            XCTAssertEqual(participant, self.participant)

            let payload = try await reader.readAll()
            XCTAssertEqual(payload, testPayload)

            receiveExpectation.fulfill()
        }

        let streamID = UUID().uuidString

        // 1. Send header packet
        var header = Livekit_DataStream.Header()
        header.streamID = streamID
        header.topic = topicName
        header.contentHeader = .byteHeader(Livekit_DataStream.ByteHeader())
        await manager.handle(header: header, from: participant.stringValue)

        // 2. Send chunk packets
        for (index, chunkData) in testChunks.enumerated() {
            var chunk = Livekit_DataStream.Chunk()
            chunk.streamID = streamID
            chunk.chunkIndex = UInt64(index)
            chunk.content = chunkData
            await manager.handle(chunk: chunk)
        }

        // 3. Send trailer packet
        var trailer = Livekit_DataStream.Trailer()
        trailer.streamID = streamID
        trailer.reason = "" // indicates normal closure
        await manager.handle(trailer: trailer)

        await fulfillment(
            of: [receiveExpectation],
            timeout: 5
        )
    }

    func testTextStream() async throws {
        let receiveExpectation = expectation(description: "Receives payload")

        let testChunks = [
            String(repeating: "A", count: 128),
            String(repeating: "B", count: 128),
            String(repeating: "C", count: 256),
            String(repeating: "D", count: 32),
        ]
        let testPayload = testChunks.reduce("") { $0 + $1 }

        try await manager.registerTextStreamHandler(for: topicName) { reader, participant in
            XCTAssertEqual(participant, self.participant)

            let payload = try await reader.readAll()
            XCTAssertEqual(payload, testPayload)

            receiveExpectation.fulfill()
        }

        let streamID = UUID().uuidString

        // 1. Send header packet
        var header = Livekit_DataStream.Header()
        header.streamID = streamID
        header.topic = topicName
        header.contentHeader = .textHeader(Livekit_DataStream.TextHeader())
        await manager.handle(header: header, from: participant.stringValue)

        // 2. Send chunk packets
        for (index, chunkData) in testChunks.enumerated() {
            var chunk = Livekit_DataStream.Chunk()
            chunk.streamID = streamID
            chunk.chunkIndex = UInt64(index)
            chunk.content = Data(chunkData.utf8)
            await manager.handle(chunk: chunk)
        }

        // 3. Send trailer packet
        var trailer = Livekit_DataStream.Trailer()
        trailer.streamID = streamID
        trailer.reason = "" // indicates normal closure
        await manager.handle(trailer: trailer)

        await fulfillment(
            of: [receiveExpectation],
            timeout: 5
        )
    }

    func testNonTextData() async throws {
        let throwsExpectation = expectation(description: "Throws error on non-text data")

        // This cannot be decoded as valid UTF-8
        let testPayload = Data(repeating: 0xAB, count: 128)

        try await manager.registerTextStreamHandler(for: topicName) { reader, _ in
            do {
                _ = try await reader.readAll()
            } catch {
                XCTAssertEqual(error as? StreamError, .decodeFailed)
                throwsExpectation.fulfill()
            }
        }

        let streamID = UUID().uuidString

        // 1. Send header packet
        var header = Livekit_DataStream.Header()
        header.streamID = streamID
        header.topic = topicName
        header.contentHeader = .textHeader(Livekit_DataStream.TextHeader())
        header.totalLength = UInt64(testPayload.count)
        await manager.handle(header: header, from: participant.stringValue)

        // 2. Send chunk packet
        var chunk = Livekit_DataStream.Chunk()
        chunk.streamID = streamID
        chunk.chunkIndex = 0
        chunk.content = Data(testPayload)
        await manager.handle(chunk: chunk)

        // 3. Send trailer packet
        var trailer = Livekit_DataStream.Trailer()
        trailer.streamID = streamID
        trailer.reason = "" // indicates normal closure
        await manager.handle(trailer: trailer)

        await fulfillment(
            of: [throwsExpectation],
            timeout: 5
        )
    }

    func testAbnormalClosure() async throws {
        let throwsExpectation = expectation(description: "Throws error on abnormal closure")
        let closureReason = "test"

        try await manager.registerByteStreamHandler(for: topicName) { reader, _ in
            do {
                _ = try await reader.readAll()
            } catch {
                XCTAssertEqual(error as? StreamError, .abnormalEnd(reason: closureReason))
                throwsExpectation.fulfill()
            }
        }

        let streamID = UUID().uuidString

        // 1. Send header packet
        var header = Livekit_DataStream.Header()
        header.streamID = streamID
        header.topic = topicName
        header.contentHeader = .byteHeader(Livekit_DataStream.ByteHeader())
        await manager.handle(header: header, from: participant.stringValue)

        // 2. Send trailer packet
        var trailer = Livekit_DataStream.Trailer()
        trailer.streamID = streamID
        trailer.reason = closureReason // indicates abnormal closure
        await manager.handle(trailer: trailer)

        await fulfillment(
            of: [throwsExpectation],
            timeout: 5
        )
    }

    func testIncomplete() async throws {
        let throwsExpectation = expectation(description: "Throws error on incomplete stream")

        let testPayload = Data(repeating: 0xAB, count: 128)

        try await manager.registerByteStreamHandler(for: topicName) { reader, _ in
            do {
                _ = try await reader.readAll()
            } catch {
                XCTAssertEqual(error as? StreamError, .incomplete)
                throwsExpectation.fulfill()
            }
        }

        let streamID = UUID().uuidString

        // 1. Send header packet
        var header = Livekit_DataStream.Header()
        header.streamID = streamID
        header.topic = topicName
        header.contentHeader = .byteHeader(Livekit_DataStream.ByteHeader())
        header.totalLength = UInt64(testPayload.count + 10) // expect more bytes
        await manager.handle(header: header, from: participant.stringValue)

        // 2. Send chunk packet
        var chunk = Livekit_DataStream.Chunk()
        chunk.streamID = streamID
        chunk.chunkIndex = 0
        chunk.content = Data(testPayload)
        await manager.handle(chunk: chunk)

        // 3. Send trailer packet
        var trailer = Livekit_DataStream.Trailer()
        trailer.streamID = streamID
        trailer.reason = "" // indicates normal closure
        await manager.handle(trailer: trailer)

        await fulfillment(
            of: [throwsExpectation],
            timeout: 5
        )
    }
}
