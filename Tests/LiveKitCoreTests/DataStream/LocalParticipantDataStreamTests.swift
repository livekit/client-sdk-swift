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

/// Sends through the public ``LocalParticipant`` API on a room whose connection delivers through a
/// test delegate, so the public wrapper, the coordinator and the core all run with no server.
@Suite(.tags(.dataStream))
struct LocalParticipantDataStreamTests {
    /// Every text option reaches the header on the wire and the info the send returns.
    @Test func textOptionsReachWireAndReturnedInfo() async throws {
        let delegate = OutgoingStreamManagerTests.CapturingDelegate()
        let room = try room(sendingThrough: delegate)

        let info = try await room.localParticipant.sendText("hi", options: LiveKit.StreamTextOptions(
            topic: "topic",
            attributes: ["foo": "bar"],
            destinationIdentities: [Participant.Identity(from: "alice")],
            id: "explicit-id",
            operationType: .update,
            version: 7,
            attachedStreamIDs: ["att-1"],
            replyToStreamID: "earlier",
            generated: true,
        ))

        let packet = try #require(delegate.packets.copy().first)
        guard case let .streamHeader(header) = packet.value, case let .textHeader(textHeader) = header.contentHeader else {
            Issue.record("The first packet is not a text stream header")
            return
        }
        #expect(packet.destinationIdentities == ["alice"])
        #expect(header.streamID == "explicit-id")
        #expect(header.topic == "topic")
        #expect(header.attributes == ["foo": "bar"])
        #expect(textHeader.operationType == .update)
        #expect(textHeader.version == 7)
        #expect(textHeader.replyToStreamID == "earlier")
        #expect(textHeader.attachedStreamIds == ["att-1"])
        #expect(textHeader.generated)

        #expect(info.id == "explicit-id")
        #expect(info.topic == "topic")
        #expect(info.attributes == ["foo": "bar"])
        #expect(info.totalLength == 2)
        #expect(info.encryptionType == .none)
        #expect(info.operationType == .update)
        #expect(info.version == 7)
        #expect(info.replyToStreamID == "earlier")
        #expect(info.attachedStreamIDs == ["att-1"])
        #expect(info.generated)
        #expect(info.mimeType == "text/plain")
    }

    /// Every byte option reaches the header on the wire and the info the send returns.
    @Test func byteOptionsReachWireAndReturnedInfo() async throws {
        let delegate = OutgoingStreamManagerTests.CapturingDelegate()
        let room = try room(sendingThrough: delegate)

        let info = try await room.localParticipant.sendBytes(Data([1, 2, 3]), options: LiveKit.StreamByteOptions(
            topic: "topic",
            attributes: ["k": "v"],
            id: "bytes-id",
            mimeType: "image/png",
            name: "pic.png",
            totalSize: 3,
        ))

        let packet = try #require(delegate.packets.copy().first)
        guard case let .streamHeader(header) = packet.value, case let .byteHeader(byteHeader) = header.contentHeader else {
            Issue.record("The first packet is not a byte stream header")
            return
        }
        #expect(header.streamID == "bytes-id")
        #expect(header.topic == "topic")
        #expect(header.mimeType == "image/png")
        #expect(byteHeader.name == "pic.png")
        #expect(header.attributes == ["k": "v"])
        #expect(header.totalLength == 3)

        #expect(info.id == "bytes-id")
        #expect(info.topic == "topic")
        #expect(info.mimeType == "image/png")
        #expect(info.name == "pic.png")
        #expect(info.attributes == ["k": "v"])
        #expect(info.totalLength == 3)
        #expect(info.encryptionType == .none)
    }

    enum Send: CaseIterable {
        case text, bytes, file, textStream, byteStream
    }

    /// `senderIdentity` reaches every packet of the stream, on each send path, including the file
    /// path that builds its own FFI options.
    @Test(arguments: Send.allCases)
    func senderIdentityReachesEveryPacket(_ send: Send) async throws {
        let delegate = OutgoingStreamManagerTests.CapturingDelegate()
        let room = try room(sendingThrough: delegate)
        let participant = room.localParticipant
        let sender = Participant.Identity(from: "on-behalf")
        let textOptions = LiveKit.StreamTextOptions(topic: "topic", senderIdentity: sender)
        let byteOptions = LiveKit.StreamByteOptions(topic: "topic", senderIdentity: sender)

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        switch send {
        case .text: _ = try await participant.sendText("hi", options: textOptions)
        case .bytes: _ = try await participant.sendBytes(Data([1]), options: byteOptions)
        case .file: _ = try await participant.sendFile(fileURL, options: byteOptions)
        case .textStream:
            let writer = try await participant.streamText(options: textOptions)
            try await writer.write("hi")
            try await writer.close()
        case .byteStream:
            let writer = try await participant.streamBytes(options: byteOptions)
            try await writer.write(Data([1]))
            try await writer.close()
        }

        let packets = delegate.packets.copy()
        #expect(!packets.isEmpty)
        #expect(packets.allSatisfy { $0.participantIdentity == "on-behalf" })
    }

    /// A one-shot send whose packets cannot be delivered fails with `.sendFailed`.
    @Test(arguments: [false, true])
    func failedDeliveryFailsOneShotSend(bytes: Bool) async throws {
        let delegate = OutgoingStreamManagerTests.CapturingDelegate()
        delegate.failsDelivery.mutate { $0 = true }
        let room = try room(sendingThrough: delegate)
        let participant = room.localParticipant

        await #expect(throws: StreamError.sendFailed) {
            if bytes {
                _ = try await participant.sendBytes(Data([1]), for: "topic")
            } else {
                _ = try await participant.sendText("hi", for: "topic")
            }
        }
    }

    // MARK: - Attachments

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

    // MARK: - Cancellation

    enum BlockedCall: CaseIterable {
        case sendText, sendBytes, sendFile, openStream, write, close
    }

    /// Holds each delivery while `blocks` is set, until `release` resolves, and reports when one
    /// starts waiting.
    private final class BlockingDelegate: OutgoingDataStreamManagerDelegate, @unchecked Sendable {
        let blocks = StateSync(true)
        let entered = AsyncCompleter<Void>(label: "Delivery blocked", defaultTimeout: 10)
        let release = AsyncCompleter<Void>(label: "Delivery released", defaultTimeout: 10)

        func onPacketsAvailable(packets _: [Data]) async throws {
            guard blocks.copy() else { return }
            entered.resume(returning: ())
            try await release.wait()
        }
    }

    /// UniFFI's async calls ignore Swift cancellation. A send, stream open, write or close whose
    /// delivery is stuck in the transport must still return when its task is cancelled.
    @Test(arguments: BlockedCall.allCases)
    func cancellingBlockedCallReturns(_ call: BlockedCall) async throws {
        let delegate = BlockingDelegate()
        defer { delegate.release.resume(returning: ()) }
        let room = try room(sendingThrough: delegate)
        let participant = room.localParticipant

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // The write and close cases need a writer, opened before deliveries start to block.
        var writer: LiveKit.TextStreamWriter?
        if call == .write || call == .close {
            delegate.blocks.mutate { $0 = false }
            writer = try await participant.streamText(for: "topic")
            delegate.blocks.mutate { $0 = true }
        }

        let returned = AsyncCompleter<Error?>(label: "Cancelled call returned", defaultTimeout: 5)
        let task = Task { [writer] in
            do {
                switch call {
                case .sendText: _ = try await participant.sendText("hi", for: "topic")
                case .sendBytes: _ = try await participant.sendBytes(Data([1]), for: "topic")
                case .sendFile: _ = try await participant.sendFile(fileURL, for: "topic")
                case .openStream: _ = try await participant.streamText(for: "topic")
                case .write: try await writer?.write("hi")
                case .close: try await writer?.close()
                }
                returned.resume(returning: nil)
            } catch {
                returned.resume(returning: error)
            }
        }
        try await delegate.entered.wait()
        task.cancel()

        #expect(try await returned.wait() is CancellationError)
    }

    // MARK: - Helpers

    /// Reads every stream that opens on an incoming manager to the end, and records the order in
    /// which they opened.
    private final class Collector: IncomingDataStreamManagerDelegate, @unchecked Sendable {
        let order = StateSync<[String]>([])
        let texts = StateSync<[(info: LiveKit.TextStreamInfo, content: String)]>([])
        let files = StateSync<[(info: LiveKit.ByteStreamInfo, content: Data)]>([])

        func onTextStreamOpened(reader: LiveKitFFI.TextStreamReader, identity _: String) {
            let reader = LiveKit.TextStreamReader(reader, info: LiveKit.TextStreamInfo(reader.info(), encryptionType: .none))
            order.mutate { $0.append(reader.info.id) }
            Task { [texts] in
                guard let content = try? await reader.readAll() else { return }
                texts.mutate { $0.append((reader.info, content)) }
            }
        }

        func onByteStreamOpened(reader: LiveKitFFI.ByteStreamReader, identity _: String) {
            let reader = LiveKit.ByteStreamReader(reader, info: LiveKit.ByteStreamInfo(reader.info(), encryptionType: .none))
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

    /// A room whose connection sends through `delegate`, so the public API runs end to end with no
    /// server. The caller keeps the room alive: the local participant holds it weakly.
    private func room(sendingThrough delegate: some OutgoingDataStreamManagerDelegate) throws -> Room {
        let room = Room()
        let connection = ConnectionDependencies(idle: room._state.stage.idle, room: room, roomOptions: RoomOptions())
        connection.outgoingDataStreams.mutate {
            $0 = DataStreams.Outgoing(manager: OutgoingDataStreamManager(delegate: delegate, registry: OutgoingStreamManagerTests.StubRegistry()), delegate: $0.delegate)
        }
        try room._state.mutate { try $0.stage.begin(connection) }
        return room
    }
}
