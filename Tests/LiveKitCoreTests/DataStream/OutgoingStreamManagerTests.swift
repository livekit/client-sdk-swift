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

/// Exercises the outgoing data-stream path against the UniFFI `OutgoingDataStreamManager` directly,
/// with a capturing delegate standing in for the data channel (the same seam the old pure-Swift
/// `OutgoingStreamManager` offered via its `packetHandler`). Validates that the pre-existing v1
/// wire behavior — a header, ordered chunks carrying the full payload, and an empty-reason trailer —
/// is produced by the new Rust core. No network or connected room is needed.
@Suite(.tags(.dataStream))
struct OutgoingStreamManagerTests {
    /// Captures the encoded `DataPacket`s the manager emits, or fails their delivery once
    /// `failsDelivery` is set.
    private final class CapturingDelegate: OutgoingDataStreamManagerDelegate, @unchecked Sendable {
        let packets = StateSync<[Livekit_DataPacket]>([])
        let failsDelivery = StateSync(false)

        func onPacketsAvailable(packets emitted: [Data]) throws {
            if failsDelivery.copy() {
                throw PacketDeliveryError.Failed(reason: "transport gone")
            }
            for data in emitted {
                guard let packet = try? Livekit_DataPacket(serializedBytes: data) else { continue }
                packets.mutate { $0.append(packet) }
            }
        }
    }

    /// Minimal registry — broadcast with no known remote capabilities.
    private final class StubRegistry: RemoteParticipantRegistryDelegate, @unchecked Sendable {
        func remoteClientProtocol(identity _: String) -> Int32 { 0 }
        func remoteCapabilities(identity _: String) -> [LiveKitFFI.ClientCapability] { [] }
        func remoteIdentities() -> [String] { [] }
    }

    @Test func streamBytes() async throws {
        let testChunks = [
            Data(repeating: 0xAB, count: 128),
            Data(repeating: 0xCD, count: 128),
            Data(repeating: 0xEF, count: 256),
            Data(repeating: 0x12, count: 32),
        ]
        let streamID = UUID().uuidString
        let topic = "some-topic"

        let delegate = CapturingDelegate()
        let manager = OutgoingDataStreamManager(delegate: delegate, registry: StubRegistry())

        let writer = try await manager.streamBytes(
            options: LiveKitFFI.StreamByteOptions(topic: topic, attributes: [:], id: streamID),
        )
        for chunk in testChunks {
            try await writer.write(data: chunk)
        }
        try await writer.close()

        assertStream(
            delegate.packets.copy(),
            streamID: streamID,
            topic: topic,
            mimeType: "application/octet-stream",
            expectedPayload: testChunks.reduce(Data()) { $0 + $1 },
        )
    }

    @Test func streamText() async throws {
        let testChunks = [
            String(repeating: "A", count: 128),
            String(repeating: "B", count: 128),
            String(repeating: "C", count: 256),
            String(repeating: "D", count: 32),
        ]
        let streamID = UUID().uuidString
        let topic = "some-topic"

        let delegate = CapturingDelegate()
        let manager = OutgoingDataStreamManager(delegate: delegate, registry: StubRegistry())

        let writer = try await manager.streamText(
            options: LiveKitFFI.StreamTextOptions(topic: topic, attributes: [:], id: streamID),
        )
        for chunk in testChunks {
            try await writer.write(text: chunk)
        }
        try await writer.close()

        assertStream(
            delegate.packets.copy(),
            streamID: streamID,
            topic: topic,
            mimeType: "text/plain",
            expectedPayload: Data(testChunks.reduce("") { $0 + $1 }.utf8),
        )
    }

    @Test func writerIsOpenReflectsClose() async throws {
        let manager = OutgoingDataStreamManager(delegate: CapturingDelegate(), registry: StubRegistry())
        let ffiWriter = try await manager.streamBytes(
            options: LiveKitFFI.StreamByteOptions(topic: "some-topic", attributes: [:]),
        )
        let writer = LiveKit.ByteStreamWriter(ffiWriter, encryptionType: .none)

        var isOpen = await writer.isOpen
        #expect(isOpen == true)

        try await writer.close()
        isOpen = await writer.isOpen
        #expect(isOpen == false)
    }

    /// The server routes each packet on its own `destinationIdentities` and broadcasts an empty
    /// list, so the chunks and trailer of a targeted stream must carry the recipients too.
    @Test(arguments: [false, true])
    func everyPacketCarriesDestinationIdentities(oneShot: Bool) async throws {
        let delegate = CapturingDelegate()
        let manager = OutgoingDataStreamManager(delegate: delegate, registry: StubRegistry())
        let options = LiveKit.StreamTextOptions(topic: "some-topic", destinationIdentities: [Participant.Identity(from: "alice")])

        if oneShot {
            // The stub registry reports no v2 recipient, so this takes the multi-packet path.
            _ = try await manager.sendText(text: "hello", options: options.ffi)
        } else {
            let writer = try await manager.streamText(options: options.ffi)
            try await writer.write(text: "hello")
            try await writer.close()
        }

        let packets = delegate.packets.copy()
        let kinds = packets.map { packet -> String in
            switch packet.value {
            case .streamHeader: "header"
            case .streamChunk: "chunk"
            case .streamTrailer: "trailer"
            default: "other"
            }
        }
        #expect(kinds == ["header", "chunk", "trailer"])
        #expect(packets.allSatisfy { $0.destinationIdentities == ["alice"] })
    }

    /// A delivery failure surfaces to the `write` that caused it and closes the stream, so the
    /// writer stops reporting itself open. Restores v1's `errorPropagation` spec.
    @Test func deliveryFailureFailsWriteAndClosesStream() async throws {
        let delegate = CapturingDelegate()
        let manager = OutgoingDataStreamManager(delegate: delegate, registry: StubRegistry())
        let ffiWriter = try await manager.streamText(
            options: LiveKitFFI.StreamTextOptions(topic: "some-topic", attributes: [:]),
        )
        let writer = LiveKit.TextStreamWriter(ffiWriter, encryptionType: .none)

        delegate.failsDelivery.mutate { $0 = true }
        await #expect(throws: StreamError.sendFailed) {
            try await writer.write("hello")
        }
        let isOpen = await writer.isOpen
        #expect(!isOpen)
    }

    // MARK: - Helpers

    /// A room whose connection sends through `delegate`, so the public API runs end to end with no
    /// server. The caller keeps the room alive: the local participant holds it weakly.
    private func room(sendingThrough delegate: some OutgoingDataStreamManagerDelegate) throws -> Room {
        let room = Room()
        let connection = ConnectionDependencies(idle: room._state.stage.idle, room: room, roomOptions: RoomOptions())
        connection.outgoingDataStreams.mutate {
            $0 = DataStreams.Outgoing(manager: OutgoingDataStreamManager(delegate: delegate, registry: StubRegistry()), delegate: $0.delegate)
        }
        try room._state.mutate { try $0.stage.begin(connection) }
        return room
    }

    private func assertStream(
        _ packets: [Livekit_DataPacket],
        streamID: String,
        topic: String,
        mimeType: String,
        expectedPayload: Data,
    ) {
        let headers = packets.compactMap { packet -> Livekit_DataStream.Header? in
            if case let .streamHeader(header) = packet.value { return header }
            return nil
        }
        #expect(headers.count == 1)
        if let header = headers.first {
            #expect(header.streamID == streamID)
            #expect(header.topic == topic)
            #expect(header.mimeType == mimeType)
        }

        let chunks = packets.compactMap { packet -> Livekit_DataStream.Chunk? in
            if case let .streamChunk(chunk) = packet.value { return chunk }
            return nil
        }
        // Robust to any re-chunking: assert the reassembled payload and sequential indices rather
        // than a one-write-per-chunk correspondence.
        let assembled = chunks.reduce(Data()) { $0 + $1.content }
        #expect(assembled == expectedPayload)
        for (index, chunk) in chunks.enumerated() {
            #expect(chunk.chunkIndex == UInt64(index))
        }
        #expect(chunks.allSatisfy { $0.streamID == streamID })

        let trailers = packets.compactMap { packet -> Livekit_DataStream.Trailer? in
            if case let .streamTrailer(trailer) = packet.value { return trailer }
            return nil
        }
        #expect(trailers.count == 1)
        #expect(trailers.first?.reason == "")
        #expect(trailers.first?.streamID == streamID)
    }
}

// MARK: - Options

extension OutgoingStreamManagerTests {
    @Test func optionDefaultsMapToFFIOptions() {
        let text = LiveKit.StreamTextOptions(topic: "t").ffi
        #expect(text.operationType == .create)
        #expect(text.generated == false)
        #expect(text.compress == true)
        #expect(LiveKit.StreamByteOptions(topic: "t").ffi.compress == true)
    }

    @Test func textOptionsMapCompletelyToFFIOptions() {
        let ffi = LiveKit.StreamTextOptions(
            topic: "topic",
            attributes: ["k": "v"],
            destinationIdentities: [Participant.Identity(from: "alice"), Participant.Identity(from: "bob")],
            id: "sid",
            operationType: .reaction,
            version: 2,
            attachedStreamIDs: ["a"],
            replyToStreamID: "r",
            generated: true,
            compress: false,
        ).ffi

        #expect(ffi.topic == "topic")
        #expect(ffi.attributes == ["k": "v"])
        #expect(ffi.destinationIdentities == ["alice", "bob"])
        #expect(ffi.id == "sid")
        #expect(ffi.operationType == .reaction)
        #expect(ffi.version == 2)
        #expect(ffi.attachedStreamIds == ["a"])
        #expect(ffi.replyToStreamId == "r")
        #expect(ffi.generated == true)
        #expect(ffi.compress == false)
    }

    @Test func byteOptionsMapCompletelyToFFIOptions() {
        let ffi = LiveKit.StreamByteOptions(
            topic: "topic",
            attributes: ["k": "v"],
            destinationIdentities: [Participant.Identity(from: "alice")],
            id: "sid",
            mimeType: "application/pdf",
            name: "doc.pdf",
            totalSize: 99,
            compress: false,
        ).ffi

        #expect(ffi.topic == "topic")
        #expect(ffi.attributes == ["k": "v"])
        #expect(ffi.destinationIdentities == ["alice"])
        #expect(ffi.id == "sid")
        #expect(ffi.mimeType == "application/pdf")
        #expect(ffi.name == "doc.pdf")
        #expect(ffi.totalLength == 99)
        #expect(ffi.compress == false)
    }

    @Test(arguments: [
        (LiveKit.TextStreamInfo.OperationType.create, LiveKitFFI.OperationType.create),
        (.update, .update),
        (.delete, .delete),
        (.reaction, .reaction),
    ])
    func operationTypeMapsToFFI(_ operationType: LiveKit.TextStreamInfo.OperationType, _ expected: LiveKitFFI.OperationType) {
        #expect(operationType.ffiValue == expected)
        #expect(LiveKit.StreamTextOptions(topic: "t", operationType: operationType).ffi.operationType == expected)
    }

    /// The registry reports these to the core, which picks inline and compressed framing from them.
    @Test(arguments: [
        (LiveKit.ClientCapability.packetTrailer, LiveKitFFI.ClientCapability.packetTrailer),
        (.compressionDeflateRaw, .compressionDeflateRaw),
    ])
    func capabilityMapsToFFI(_ capability: LiveKit.ClientCapability, _ expected: LiveKitFFI.ClientCapability) {
        #expect(capability.ffiValue == expected)
    }

    /// Every text option reaches the header on the wire and the info the send returns.
    @Test func textOptionsReachWireAndReturnedInfo() async throws {
        let delegate = CapturingDelegate()
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
        let delegate = CapturingDelegate()
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
}
