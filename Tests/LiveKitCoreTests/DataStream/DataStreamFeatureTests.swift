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

/// Stream features between real rooms that the Rust core carries end to end.
extension DataStreamTests {
    /// The attributes a sender sets when it closes a stream reach the receiver's info once the
    /// stream has ended, and replace header attributes with the same key.
    @Test(arguments: [false, true])
    func closeAttributesReachTheReceiver(text: Bool) async throws {
        let header = ["kept": "header", "replaced": "header"]
        let trailer = ["replaced": "trailer", "added": "trailer"]

        try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
            let (receiver, sender) = (rooms[0], rooms[1])
            let received = AsyncCompleter<[String: String]>(label: "Attributes after the end", defaultTimeout: 30)
            if text {
                try await receiver.registerTextStreamHandler(for: "attributes") { reader, _ in
                    do {
                        _ = try await reader.readAll()
                        received.resume(returning: reader.info.attributes)
                    } catch {
                        received.resume(throwing: error)
                    }
                }
                let writer = try await sender.localParticipant.streamText(options: StreamTextOptions(topic: "attributes", attributes: header))
                try await writer.write("hello")
                try await writer.close(attributes: trailer)
            } else {
                try await receiver.registerByteStreamHandler(for: "attributes") { reader, _ in
                    do {
                        _ = try await reader.readAll()
                        received.resume(returning: reader.info.attributes)
                    } catch {
                        received.resume(throwing: error)
                    }
                }
                let writer = try await sender.localParticipant.streamBytes(options: StreamByteOptions(topic: "attributes", attributes: header))
                try await writer.write(Data("hello".utf8))
                try await writer.close(attributes: trailer)
            }

            #expect(try await received.wait() == ["kept": "header", "replaced": "trailer", "added": "trailer"])
        }
    }

    /// A send reports its progress in payload bytes before compression, rising to the whole
    /// payload: a one-shot text or byte send once, when it completes, and a file as it goes out.
    @Test(arguments: [Send.text, .bytes, .file])
    func sendReportsProgress(via send: Send) async throws {
        let payload = send == .file ? Self.noisy(200_000) : Data("Hello world!".utf8)
        let updates = StateSync<[StreamProgress]>([])
        let onProgress: @Sendable (StreamProgress) -> Void = { progress in updates.mutate { $0.append(progress) } }

        try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
            let sender = rooms[1].localParticipant
            switch send {
            case .text:
                try await sender.sendText(String(bytes: payload, encoding: .utf8) ?? "", options: StreamTextOptions(topic: "progress"), onProgress: onProgress)
            case .bytes:
                try await sender.sendBytes(payload, options: StreamByteOptions(topic: "progress"), onProgress: onProgress)
            default:
                let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bin")
                try payload.write(to: fileURL)
                defer { try? FileManager.default.removeItem(at: fileURL) }
                try await sender.sendFile(fileURL, options: StreamByteOptions(topic: "progress"), onProgress: onProgress)
            }
        }

        let reported = updates.copy()
        if send.mayGoInline {
            #expect(reported.count == 1)
        } else {
            #expect(reported.count > 1)
        }
        #expect(zip(reported, reported.dropFirst()).allSatisfy { $0.bytesProcessed <= $1.bytesProcessed })
        #expect(reported.allSatisfy { $0.bytesTotal == payload.count })
        #expect(reported.last?.bytesProcessed == payload.count)
        #expect(reported.last?.fraction == 1)
    }

    /// A reader reports the bytes it received, rising to the whole payload. The total is the size
    /// the sender declared, and unknown for a text stream opened without one.
    @Test(arguments: [Send.file, .textStream])
    func readerReportsProgress(via send: Send) async throws {
        let payload = Self.noisy(60000)

        try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
            let (receiver, sender) = (rooms[0], rooms[1])
            let received = AsyncCompleter<[StreamProgress]>(label: "Progress of the stream", defaultTimeout: 30)
            try await receiver.registerByteStreamHandler(for: "progress") { reader, _ in
                async let updates = reader.progress.reduce(into: [StreamProgress]()) { $0.append($1) }
                do {
                    _ = try await reader.readAll()
                    await received.resume(returning: updates)
                } catch {
                    received.resume(throwing: error)
                }
            }
            try await receiver.registerTextStreamHandler(for: "progress") { reader, _ in
                async let updates = reader.progress.reduce(into: [StreamProgress]()) { $0.append($1) }
                do {
                    _ = try await reader.readAll()
                    await received.resume(returning: updates)
                } catch {
                    received.resume(throwing: error)
                }
            }

            if send == .file {
                let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bin")
                try payload.write(to: fileURL)
                defer { try? FileManager.default.removeItem(at: fileURL) }
                try await sender.localParticipant.sendFile(fileURL, for: "progress")
            } else {
                let writer = try await sender.localParticipant.streamText(for: "progress")
                for start in stride(from: 0, to: payload.count, by: 15000) {
                    try await writer.write(String(bytes: payload[start ..< min(start + 15000, payload.count)], encoding: .utf8) ?? "")
                }
                try await writer.close()
            }

            let reported = try await received.wait()
            #expect(!reported.isEmpty)
            #expect(zip(reported, reported.dropFirst()).allSatisfy { $0.bytesProcessed <= $1.bytesProcessed })
            #expect(reported.allSatisfy { $0.bytesTotal == (send == .file ? payload.count : nil) })
            #expect(reported.last?.bytesProcessed == payload.count)
        }
    }

    /// A text stream opened with a declared size carries it to the receiver, which reads a stream
    /// that matches it and fails one that ends short with `.incomplete`.
    @Test(arguments: [true, false])
    func declaredTextSizeIsChecked(matches: Bool) async throws {
        let text = "Hello world!"
        let declared = text.utf8.count + (matches ? 0 : 5)

        try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
            let (receiver, sender) = (rooms[0], rooms[1])
            let received = AsyncCompleter<(totalLength: Int?, text: Result<String, Error>)>(label: "Stream read", defaultTimeout: 30)
            try await receiver.registerTextStreamHandler(for: "declared") { reader, _ in
                do {
                    try await received.resume(returning: (reader.info.totalLength, .success(reader.readAll())))
                } catch {
                    received.resume(returning: (reader.info.totalLength, .failure(error)))
                }
            }

            let writer = try await sender.localParticipant.streamText(options: StreamTextOptions(topic: "declared", totalSize: declared))
            #expect(writer.info.totalLength == declared)
            try await writer.write(text)
            try await writer.close()

            let outcome = try await received.wait()
            #expect(outcome.totalLength == declared)
            if matches {
                #expect(try outcome.text.get() == text)
            } else {
                #expect(throws: StreamError.incomplete) { try outcome.text.get() }
            }
        }
    }
}
