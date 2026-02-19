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

struct IncomingStreamManagerTests: @unchecked Sendable {
    private var manager: IncomingStreamManager

    private let topicName = "someTopic"
    private let participant = Participant.Identity(from: "someName")

    init() {
        manager = IncomingStreamManager()
    }

    @Test func registerByteHandler() async throws {
        try await manager.registerByteStreamHandler(for: topicName) { _, _ in }

        try await confirmation("Throws on duplicate registration") { confirm in
            do {
                try await manager.registerByteStreamHandler(for: topicName) { _, _ in }
            } catch {
                #expect(error as? StreamError == .handlerAlreadyRegistered)
                confirm()
            }
        }

        await manager.unregisterByteStreamHandler(for: topicName)
    }

    @Test func registerTextHandler() async throws {
        try await manager.registerTextStreamHandler(for: topicName) { _, _ in }

        try await confirmation("Throws on duplicate registration") { confirm in
            do {
                try await manager.registerTextStreamHandler(for: topicName) { _, _ in }
            } catch {
                #expect(error as? StreamError == .handlerAlreadyRegistered)
                confirm()
            }
        }

        await manager.unregisterTextStreamHandler(for: topicName)
    }

    @Test func byteStream() async throws {
        try await confirmation("Receives payload") { confirm in
            let testChunks = [
                Data(repeating: 0xAB, count: 128),
                Data(repeating: 0xCD, count: 128),
                Data(repeating: 0xEF, count: 256),
                Data(repeating: 0x12, count: 32),
            ]
            let testPayload = testChunks.reduce(Data()) { $0 + $1 }

            try await manager.registerByteStreamHandler(for: topicName) { reader, participant in
                #expect(participant == self.participant)

                let payload = try await reader.readAll()
                #expect(payload == testPayload)

                confirm()
            }

            let streamID = UUID().uuidString

            // 1. Send header packet
            var header = Livekit_DataStream.Header()
            header.streamID = streamID
            header.topic = topicName
            header.contentHeader = .byteHeader(Livekit_DataStream.ByteHeader())
            manager.handle(.header(header, participant.stringValue, .none))

            // 2. Send chunk packets
            for (index, chunkData) in testChunks.enumerated() {
                var chunk = Livekit_DataStream.Chunk()
                chunk.streamID = streamID
                chunk.chunkIndex = UInt64(index)
                chunk.content = chunkData
                manager.handle(.chunk(chunk, .none))
            }

            // 3. Send trailer packet
            var trailer = Livekit_DataStream.Trailer()
            trailer.streamID = streamID
            trailer.reason = "" // indicates normal closure
            manager.handle(.trailer(trailer, .none))

            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    @Test func textStream() async throws {
        try await confirmation("Receives payload") { confirm in
            let testChunks = [
                String(repeating: "A", count: 128),
                String(repeating: "B", count: 128),
                String(repeating: "C", count: 256),
                String(repeating: "D", count: 32),
            ]
            let testPayload = testChunks.reduce("") { $0 + $1 }

            try await manager.registerTextStreamHandler(for: topicName) { reader, participant in
                #expect(participant == self.participant)

                let payload = try await reader.readAll()
                #expect(payload == testPayload)

                confirm()
            }

            let streamID = UUID().uuidString

            // 1. Send header packet
            var header = Livekit_DataStream.Header()
            header.streamID = streamID
            header.topic = topicName
            header.contentHeader = .textHeader(Livekit_DataStream.TextHeader())
            manager.handle(.header(header, participant.stringValue, .none))

            // 2. Send chunk packets
            for (index, chunkData) in testChunks.enumerated() {
                var chunk = Livekit_DataStream.Chunk()
                chunk.streamID = streamID
                chunk.chunkIndex = UInt64(index)
                chunk.content = Data(chunkData.utf8)
                manager.handle(.chunk(chunk, .none))
            }

            // 3. Send trailer packet
            var trailer = Livekit_DataStream.Trailer()
            trailer.streamID = streamID
            trailer.reason = "" // indicates normal closure
            manager.handle(.trailer(trailer, .none))

            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    @Test func nonTextData() async throws {
        try await confirmation("Throws error on non-text data") { confirm in
            // This cannot be decoded as valid UTF-8
            let testPayload = Data(repeating: 0xAB, count: 128)

            try await manager.registerTextStreamHandler(for: topicName) { reader, _ in
                do {
                    _ = try await reader.readAll()
                } catch {
                    #expect(error as? StreamError == .decodeFailed)
                    confirm()
                }
            }

            let streamID = UUID().uuidString

            // 1. Send header packet
            var header = Livekit_DataStream.Header()
            header.streamID = streamID
            header.topic = topicName
            header.contentHeader = .textHeader(Livekit_DataStream.TextHeader())
            header.totalLength = UInt64(testPayload.count)
            manager.handle(.header(header, participant.stringValue, .none))

            // 2. Send chunk packet
            var chunk = Livekit_DataStream.Chunk()
            chunk.streamID = streamID
            chunk.chunkIndex = 0
            chunk.content = Data(testPayload)
            manager.handle(.chunk(chunk, .none))

            // 3. Send trailer packet
            var trailer = Livekit_DataStream.Trailer()
            trailer.streamID = streamID
            trailer.reason = "" // indicates normal closure
            manager.handle(.trailer(trailer, .none))

            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    @Test func abnormalClosure() async throws {
        try await confirmation("Throws error on abnormal closure") { confirm in
            let closureReason = "test"

            try await manager.registerByteStreamHandler(for: topicName) { reader, _ in
                do {
                    _ = try await reader.readAll()
                } catch {
                    #expect(error as? StreamError == .abnormalEnd(reason: closureReason))
                    confirm()
                }
            }

            let streamID = UUID().uuidString

            // 1. Send header packet
            var header = Livekit_DataStream.Header()
            header.streamID = streamID
            header.topic = topicName
            header.contentHeader = .byteHeader(Livekit_DataStream.ByteHeader())
            manager.handle(.header(header, participant.stringValue, .none))

            // 2. Send trailer packet
            var trailer = Livekit_DataStream.Trailer()
            trailer.streamID = streamID
            trailer.reason = closureReason // indicates abnormal closure
            manager.handle(.trailer(trailer, .none))

            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    @Test func incomplete() async throws {
        try await confirmation("Throws error on incomplete stream") { confirm in
            let testPayload = Data(repeating: 0xAB, count: 128)

            try await manager.registerByteStreamHandler(for: topicName) { reader, _ in
                do {
                    _ = try await reader.readAll()
                } catch {
                    #expect(error as? StreamError == .incomplete)
                    confirm()
                }
            }

            let streamID = UUID().uuidString

            // 1. Send header packet
            var header = Livekit_DataStream.Header()
            header.streamID = streamID
            header.topic = topicName
            header.contentHeader = .byteHeader(Livekit_DataStream.ByteHeader())
            header.totalLength = UInt64(testPayload.count + 10) // expect more bytes
            manager.handle(.header(header, participant.stringValue, .none))

            // 2. Send chunk packet
            var chunk = Livekit_DataStream.Chunk()
            chunk.streamID = streamID
            chunk.chunkIndex = 0
            chunk.content = Data(testPayload)
            manager.handle(.chunk(chunk, .none))

            // 3. Send trailer packet
            var trailer = Livekit_DataStream.Trailer()
            trailer.streamID = streamID
            trailer.reason = "" // indicates normal closure
            manager.handle(.trailer(trailer, .none))

            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    @Test func encryptionTypeMismatch() async throws {
        let manager = IncomingStreamManager()
        let topic = "test-encryption-mismatch"

        try await confirmation("Stream should receive error") { confirm in
            try await manager.registerByteStreamHandler(for: topic) { reader, _ in
                do {
                    _ = try await reader.readAll()
                } catch let error as StreamError {
                    if case let .encryptionTypeMismatch(expected, received) = error {
                        #expect(expected == .gcm) // Stream was created with .gcm
                        #expect(received == .none) // But chunk sent with .none
                        confirm()
                    } else {
                        Issue.record("Expected encryptionTypeMismatch error, got \(error)")
                    }
                }
            }
            var header = Livekit_DataStream.Header()
            header.streamID = "test-stream-id"
            header.topic = topic
            header.mimeType = "application/octet-stream"
            header.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            header.contentHeader = .byteHeader(.with {
                $0.name = "test-file.bin"
            })

            manager.handle(.header(header, "test-participant", .gcm))

            var chunk = Livekit_DataStream.Chunk()
            chunk.streamID = "test-stream-id"
            chunk.chunkIndex = 0
            chunk.content = Data("test data".utf8)

            manager.handle(.chunk(chunk, .none))

            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}
