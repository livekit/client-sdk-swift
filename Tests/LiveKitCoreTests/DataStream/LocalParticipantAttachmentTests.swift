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

/// Files attached to a one-shot `sendText`, between two real rooms: the order, IDs, content and
/// topic each receiver sees, and how a failure or a cancel ends the call.
@Suite(.serialized, .tags(.dataStream, .e2e), TestLimits.e2e)
struct LocalParticipantAttachmentTests {
    /// The text goes first and lists one stream ID per file. Each file then arrives as a byte stream
    /// with its ID, on the text's topic, with the file's content.
    @Test func attachmentsArriveWithTheirIDs() async throws {
        let files = try (0 ..< 2).map { try temporaryFile(byte: UInt8($0), count: 100) }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }

        try await withSenderAndReceiver { sender, receiver in
            let collector = try await Collector(on: receiver)
            let info = try await sender.localParticipant.sendText("see attached", options: LiveKit.StreamTextOptions(topic: "chat"), attachments: files)

            #expect(info.attachedStreamIDs.count == files.count)
            try await poll(timeout: 30, for: "the text and both files") {
                collector.texts.copy().count == 1 && collector.files.copy().count == files.count
            }
            #expect(collector.order.copy().first == info.id)
            let text = try #require(collector.texts.copy().first)
            #expect(text.content == "see attached")
            #expect(text.info.attachedStreamIDs == info.attachedStreamIDs)
            for (url, id) in zip(files, info.attachedStreamIDs) {
                let file = try #require(collector.files.copy().first { $0.info.id == id })
                #expect(try file.content == Data(contentsOf: url))
                #expect(file.info.topic == "chat")
            }
        }
    }

    /// A file that cannot be read fails the call at once, even with another file in the call.
    @Test func missingAttachmentFailsAtOnce() async throws {
        let file = try temporaryFile(byte: 0x5A, count: 100)
        defer { try? FileManager.default.removeItem(at: file) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-missing.bin")

        try await withSenderAndReceiver { sender, _ in
            let error = try await returnedError {
                try await sender.localParticipant.sendText("see attached", options: LiveKit.StreamTextOptions(topic: "chat"), attachments: [file, missing])
            }
            #expect(error as? StreamError == .fileInfoUnavailable)
        }
    }

    /// Cancelling the call ends it at once, while its file sends are still in flight.
    ///
    /// The native transport cannot be held from Swift, so large files keep the sends in flight: the
    /// call is cancelled when the receiver sees the text, before any file can have finished.
    @Test func cancellingAttachmentsEndsAllSends() async throws {
        let files = try (0 ..< 2).map { _ in try temporaryFile(byte: 0x5A, count: 32 * 1024 * 1024) }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }

        try await withSenderAndReceiver { sender, receiver in
            let textArrived = AsyncCompleter<Void>(label: "Text arrived", defaultTimeout: 30)
            try await receiver.registerTextStreamHandler(for: "chat") { _, _ in textArrived.resume(returning: ()) }

            let error = try await returnedError(cancellingAfter: textArrived) {
                try await sender.localParticipant.sendText("see attached", options: LiveKit.StreamTextOptions(topic: "chat"), attachments: files)
            }
            #expect(error is CancellationError)
        }
    }

    // MARK: - Helpers

    private func withSenderAndReceiver(_ body: @escaping (_ sender: Room, _ receiver: Room) async throws -> Void) async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublishData: true), RoomTestingOptions(canSubscribe: true)]) { rooms in
            try await body(rooms[0], rooms[1])
        }
    }

    private func temporaryFile(byte: UInt8, count: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bin")
        try Data(repeating: byte, count: count).write(to: url)
        return url
    }

    /// Runs `send` in a task, cancels it once `signal` resolves if one is given, and returns the
    /// error it threw, or `nil`. Fails if the task has not returned within 5 s of that point.
    private func returnedError(cancellingAfter signal: AsyncCompleter<Void>? = nil,
                               _ send: @escaping @Sendable () async throws -> Void) async throws -> Error?
    {
        let returned = AsyncCompleter<Error?>(label: "Send returned", defaultTimeout: 5)
        let task = Task {
            do {
                try await send()
                returned.resume(returning: nil)
            } catch {
                returned.resume(returning: error)
            }
        }
        if let signal {
            try await signal.wait()
            task.cancel()
        }
        return try await returned.wait()
    }

    /// Reads every stream on the "chat" topic of `room` to the end, and records the order in which
    /// they opened.
    private final class Collector: Sendable {
        let order = StateSync<[String]>([])
        let texts = StateSync<[(info: LiveKit.TextStreamInfo, content: String)]>([])
        let files = StateSync<[(info: LiveKit.ByteStreamInfo, content: Data)]>([])

        init(on room: Room) async throws {
            try await room.registerTextStreamHandler(for: "chat") { [order, texts] reader, _ in
                order.mutate { $0.append(reader.info.id) }
                let content = try await reader.readAll()
                texts.mutate { $0.append((reader.info, content)) }
            }
            try await room.registerByteStreamHandler(for: "chat") { [order, files] reader, _ in
                order.mutate { $0.append(reader.info.id) }
                let content = try await reader.readAll()
                files.mutate { $0.append((reader.info, content)) }
            }
        }
    }
}
