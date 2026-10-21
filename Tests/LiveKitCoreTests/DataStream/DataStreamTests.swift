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

@Suite(.serialized, .tags(.dataStream, .e2e), TestLimits.e2e)
struct DataStreamTests {
    enum Method: CaseIterable, CustomTestStringConvertible {
        case send, stream

        var testDescription: String {
            switch self {
            case .send: "send"
            case .stream: "stream"
            }
        }
    }

    @Test(arguments: Method.allCases)
    func textDataStream(via method: Method) async throws {
        let topic = "some-topic"
        let testChunk = "Hello world!"

        let delivered = AsyncCompleter<Void>(label: "Text stream delivered", defaultTimeout: 30)

        try await confirmation("Receives stream chunk") { confirm in
            try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
                let room0 = rooms[0]
                let room1 = rooms[1]

                try await room0.registerTextStreamHandler(for: topic) { reader, participant in
                    #expect(participant == room1.localParticipant.identity)
                    do {
                        let chunk = try await reader.readAll()
                        #expect(chunk == testChunk)
                        confirm()
                    } catch {
                        Issue.record("Read failed: \(error.localizedDescription)")
                    }
                    delivered.resume(returning: ())
                }

                do {
                    switch method {
                    case .send:
                        try await room1.localParticipant.sendText(testChunk, for: topic)
                    case .stream:
                        let writer = try await room1.localParticipant.streamText(for: topic)
                        try await writer.write(testChunk)
                        try await writer.close()
                    }
                } catch {
                    Issue.record("Write failed: \(error.localizedDescription)")
                }

                // Waits for the handler, not for a second of wall clock: the handler runs on its
                // own task and a loaded runner routinely needs longer than a fixed sleep allows,
                // which is what made these confirm zero times on CI. The stream rides the
                // *reliable* channel, so a timeout here is a real failure, not a tolerable drop —
                // hence a budget that covers scheduling on the slowest leg rather than one that
                // doubles as a latency assertion.
                try await delivered.wait()
            }
        }
    }

    enum ByteMethod: CaseIterable {
        case sendFile, sendBytes, stream
    }

    @Test(arguments: ByteMethod.allCases)
    func byteDataStream(via method: ByteMethod) async throws {
        let topic = "some-topic"
        let testChunk = Data(repeating: 0xFF, count: 256)

        let delivered = AsyncCompleter<Void>(label: "Byte stream delivered", defaultTimeout: 30)

        try await confirmation("Receives stream chunk") { confirm in
            try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
                let room0 = rooms[0]
                let room1 = rooms[1]

                try await room0.registerByteStreamHandler(for: topic) { reader, participant in
                    #expect(participant == room1.localParticipant.identity)
                    do {
                        let chunk = try await reader.readAll()
                        #expect(chunk == testChunk)
                        confirm()
                    } catch {
                        Issue.record("Read failed: \(error.localizedDescription)")
                    }
                    delivered.resume(returning: ())
                }

                do {
                    switch method {
                    case .sendFile:
                        let fileURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("file-name.pdf")
                        try testChunk.write(to: fileURL)

                        let info = try await room1.localParticipant.sendFile(fileURL, for: topic)

                        #expect(info.name == fileURL.lastPathComponent)
                        #expect(info.mimeType == "application/pdf")
                        #expect(info.totalLength == testChunk.count)

                    case .sendBytes:
                        let info = try await room1.localParticipant.sendBytes(testChunk, for: topic)

                        #expect(info.mimeType == "application/octet-stream")
                        #expect(info.totalLength == testChunk.count)

                    case .stream:
                        let writer = try await room1.localParticipant.streamBytes(for: topic)
                        try await writer.write(testChunk)
                        try await writer.close()
                    }
                } catch {
                    Issue.record("Write failed: \(error.localizedDescription)")
                }

                // Waits for the handler, not for a second of wall clock: the handler runs on its
                // own task and a loaded runner routinely needs longer than a fixed sleep allows,
                // which is what made these confirm zero times on CI. The stream rides the
                // *reliable* channel, so a timeout here is a real failure, not a tolerable drop —
                // hence a budget that covers scheduling on the slowest leg rather than one that
                // doubles as a latency assertion.
                try await delivered.wait()
            }
        }
    }

    /// A large, compressible payload between two v2 rooms: the sender compresses it into chunks,
    /// and the receiver reads back exactly what was sent.
    @Test(arguments: ByteMethod.allCases + [nil])
    func largeCompressiblePayloadArrives(via method: ByteMethod?) async throws {
        let text = String(repeating: "compress me, please. ", count: 15000)
        let payload = Data(text.utf8)
        let received = AsyncCompleter<Data>(label: "Large payload received", defaultTimeout: 30)

        try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
            let (receiver, sender) = (rooms[0], rooms[1])
            try await receiver.registerTextStreamHandler(for: "large") { reader, _ in
                do {
                    try await received.resume(returning: Data(reader.readAll().utf8))
                } catch {
                    received.resume(throwing: error)
                }
            }
            try await receiver.registerByteStreamHandler(for: "large") { reader, _ in
                do {
                    try await received.resume(returning: reader.readAll())
                } catch {
                    received.resume(throwing: error)
                }
            }

            switch method {
            case nil:
                try await sender.localParticipant.sendText(text, for: "large")
            case .sendBytes:
                try await sender.localParticipant.sendBytes(payload, for: "large")
            case .sendFile:
                let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
                try payload.write(to: fileURL)
                defer { try? FileManager.default.removeItem(at: fileURL) }
                try await sender.localParticipant.sendFile(fileURL, for: "large")
            case .stream:
                let writer = try await sender.localParticipant.streamBytes(for: "large")
                try await writer.write(payload)
                try await writer.close()
            }

            #expect(try await received.wait() == payload)
        }
    }

    /// The receiver's configured cap holds a payload sent from another room: a payload under the
    /// cap reads, and one over it fails with `.payloadTooLarge`.
    @Test func receiverPayloadCapHoldsAcrossRooms() async throws {
        let results = StateSync<[Result<String, Error>]>([])

        try await TestEnvironment.withRooms([
            RoomTestingOptions(dataStreamOptions: DataStreamOptions(maxPayloadByteLength: 1000), canSubscribe: true),
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let (receiver, sender) = (rooms[0], rooms[1])
            try await receiver.registerTextStreamHandler(for: "capped") { reader, _ in
                do {
                    let text = try await reader.readAll()
                    results.mutate { $0.append(.success(text)) }
                } catch {
                    results.mutate { $0.append(.failure(error)) }
                }
            }

            let small = String(repeating: "a", count: 500)
            try await sender.localParticipant.sendText(small, for: "capped")
            try await poll(timeout: 30, for: "the small payload") { results.copy().count == 1 }
            try await sender.localParticipant.sendText(String(repeating: "b", count: 5000), for: "capped")
            try await poll(timeout: 30, for: "the large payload") { results.copy().count == 2 }

            let outcomes = results.copy()
            #expect(try outcomes[0].get() == small)
            #expect(throws: StreamError.payloadTooLarge) { try outcomes[1].get() }
        }
    }

    enum ReservedRegisterOp: CaseIterable, CustomTestStringConvertible {
        case text
        case byte

        var testDescription: String {
            switch self {
            case .text: "registerTextStreamHandler"
            case .byte: "registerByteStreamHandler"
            }
        }

        func invoke(on room: Room, topic: String) async throws {
            switch self {
            case .text: try await room.registerTextStreamHandler(for: topic) { _, _ in }
            case .byte: try await room.registerByteStreamHandler(for: topic) { _, _ in }
            }
        }
    }

    /// The public `Room.register*StreamHandler` APIs reject user calls on the reserved
    /// `lk.rpc*` topic family so user code can't shadow the SDK's RPC v2 stream handlers
    /// (`lk.rpc_request` / `lk.rpc_response`). The unregister APIs are non-throwing by
    /// signature and silently no-op on the same prefix, so they don't need a runtime
    /// assertion.
    @Test(arguments: ReservedRegisterOp.allCases, ["lk.rpc_request", "lk.rpc_response", "lk.rpc_future"])
    func reservedPrefixRegisterRejected(_ op: ReservedRegisterOp, _ topic: String) async throws {
        try await TestEnvironment.withRoom { room in
            await #expect(throws: LiveKitError.self) {
                try await op.invoke(on: room, topic: topic)
            }
        }
    }
}
