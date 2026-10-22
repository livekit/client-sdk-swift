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
import LiveKitFFI
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Files attached to a one-shot `sendText`: the order and IDs on the wire, and how a failure or a
/// cancel ends the call.
extension LocalParticipantDataStreamTests {
    /// The text goes first and lists one stream ID per file. Each file then arrives as a byte stream
    /// with its ID, on the text's topic, with the file's content.
    @Test func attachmentsArriveWithTheirIDs() async throws {
        let collector = Collector()
        let room = try room(sendingThrough: Forwarder(to: collector))
        let files = try (0 ..< 2).map { index in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bin")
            try Data(repeating: UInt8(index), count: 100).write(to: url)
            return url
        }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }

        let info = try await room.localParticipant.sendText("see attached", options: LiveKit.StreamTextOptions(topic: "chat"), attachments: files)

        #expect(info.attachedStreamIDs.count == files.count)
        try await poll(for: "the text and both files") {
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

    /// A file that cannot be read fails the call at once, while another file's send waits in the
    /// transport; that send is cancelled rather than awaited.
    @Test func missingAttachmentFailsAtOnce() async throws {
        let delegate = FileBlockingDelegate()
        defer { delegate.release.resume(returning: ()) }
        let room = try room(sendingThrough: delegate)
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-missing.bin")

        let error = try await returnedError {
            try await room.localParticipant.sendText("see attached", options: LiveKit.StreamTextOptions(topic: "chat"), attachments: [file, missing])
        }
        #expect(error as? StreamError == .fileInfoUnavailable)
    }

    /// Cancelling the call ends every send it started, including those stuck in the transport.
    @Test func cancellingAttachmentsEndsAllSends() async throws {
        let delegate = FileBlockingDelegate()
        defer { delegate.release.resume(returning: ()) }
        let room = try room(sendingThrough: delegate)
        let files = try [temporaryFile(), temporaryFile()]
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }

        let error = try await returnedError(cancellingAfter: delegate.entered) {
            try await room.localParticipant.sendText("see attached", options: LiveKit.StreamTextOptions(topic: "chat"), attachments: files)
        }
        #expect(error is CancellationError)
    }

    /// Holds every delivery of a byte stream header until `release` resolves, and reports when the
    /// first one starts waiting. Text goes straight through.
    private final class FileBlockingDelegate: OutgoingDataStreamManagerDelegate, @unchecked Sendable {
        let entered = AsyncCompleter<Void>(label: "File delivery blocked", defaultTimeout: 10)
        let release = AsyncCompleter<Void>(label: "File delivery released", defaultTimeout: 10)

        func onPacketsAvailable(packets: [Data]) async throws {
            let carriesFileHeader = packets.contains { data in
                guard case let .streamHeader(header)? = (try? Livekit_DataPacket(serializedBytes: data))?.value,
                      case .byteHeader? = header.contentHeader else { return false }
                return true
            }
            guard carriesFileHeader else { return }
            entered.resume(returning: ())
            try await release.wait()
        }
    }

    private func temporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bin")
        try Data(repeating: 0x5A, count: 100).write(to: url)
        return url
    }

    /// Runs `send` in a task, cancels it once `signal` resolves if one is given, and returns the
    /// error it threw, or `nil`. Fails if the task has not returned within 5 s.
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

    /// Reads every stream that opens on an incoming manager to the end, and records the order in
    /// which they opened.
    private final class Collector: IncomingDataStreamManagerDelegate, @unchecked Sendable {
        let order = StateSync<[String]>([])
        let texts = StateSync<[(info: LiveKit.TextStreamInfo, content: String)]>([])
        let files = StateSync<[(info: LiveKit.ByteStreamInfo, content: Data)]>([])

        func onTextStreamOpened(reader: LiveKitFFI.TextStreamReader, identity _: String) {
            let reader = LiveKit.TextStreamReader(reader)
            order.mutate { $0.append(reader.info.id) }
            Task { [texts] in
                guard let content = try? await reader.readAll() else { return }
                texts.mutate { $0.append((reader.info, content)) }
            }
        }

        func onByteStreamOpened(reader: LiveKitFFI.ByteStreamReader, identity _: String) {
            let reader = LiveKit.ByteStreamReader(reader)
            order.mutate { $0.append(reader.info.id) }
            Task { [files] in
                guard let content = try? await reader.readAll() else { return }
                files.mutate { $0.append((reader.info, content)) }
            }
        }

        func onStreamClosed(streamId _: String, identity _: String) {}
    }

    /// Hands every packet straight to an incoming manager that reports to `collector`.
    private final class Forwarder: OutgoingDataStreamManagerDelegate, @unchecked Sendable {
        private let incoming: IncomingDataStreamManager

        init(to collector: Collector) {
            incoming = IncomingDataStreamManager(delegate: collector, maxPayloadByteLength: nil)
        }

        func onPacketsAvailable(packets: [Data]) {
            for packet in packets {
                incoming.handlePacketReceived(packet: packet, encryptionType: .none)
            }
        }
    }
}
