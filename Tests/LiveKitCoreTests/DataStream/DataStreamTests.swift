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
    /// One way to send a stream from the public API.
    enum Send: CaseIterable, Sendable {
        case text, textStream, bytes, file, byteStream

        var isText: Bool {
            self == .text || self == .textStream
        }

        /// One-shot sends may be compressed; a stream opened up front never is.
        var isOneShot: Bool {
            self != .textStream && self != .byteStream
        }

        /// Only a payload already in memory may go inline in its header; a file goes in chunks.
        var mayGoInline: Bool {
            self == .text || self == .bytes
        }

        func perform(_ payload: Data, topic: String, from participant: LocalParticipant) async throws {
            let text = String(bytes: payload, encoding: .utf8) ?? ""
            switch self {
            case .text:
                let info = try await participant.sendText(text, for: topic)
                #expect(info.totalLength == payload.count)
            case .textStream:
                let writer = try await participant.streamText(for: topic)
                try await writer.write(text)
                try await writer.close()
            case .bytes:
                let info = try await participant.sendBytes(payload, for: topic)
                #expect(info.mimeType == "application/octet-stream")
                #expect(info.totalLength == payload.count)
            case .file:
                let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
                try payload.write(to: fileURL)
                defer { try? FileManager.default.removeItem(at: fileURL) }
                let info = try await participant.sendFile(fileURL, for: topic)
                #expect(info.name == fileURL.lastPathComponent)
                #expect(info.mimeType == "application/pdf")
                #expect(info.totalLength == payload.count)
            case .byteStream:
                let writer = try await participant.streamBytes(for: topic)
                try await writer.write(payload)
                try await writer.close()
            }
        }
    }

    /// Who sends to whom, by the protocol each room advertises.
    struct Peers: Sendable, CustomTestStringConvertible {
        let testDescription: String
        /// Each receiver's protocol; `nil` is the SDK's own, v2.
        let receivers: [ClientProtocol?]
        /// The sender's protocol; `nil` is the SDK's own, v2.
        var sender: ClientProtocol?
    }

    static let peers = [
        Peers(testDescription: "v2 to v2", receivers: [nil]),
        Peers(testDescription: "v2 to v1", receivers: [.v1]),
        Peers(testDescription: "v1 to v2", receivers: [nil], sender: .v1),
        Peers(testDescription: "v2 broadcast to v1 and v2", receivers: [.v1, nil]),
    ]

    /// A stream between real rooms whose peers advertise different protocols. Each side sees the
    /// protocol the other advertised, the sender picks a framing every receiver it sees can read,
    /// and each receiver reads exactly what was sent.
    @Test(arguments: peers, Send.allCases)
    func streamRoundTrips(between peers: Peers, via send: Send) async throws {
        let payload = send.isText ? Data("Hello world!".utf8) : Data(repeating: 0xFF, count: 256)
        let options = peers.receivers.map { RoomTestingOptions(clientProtocol: $0, canSubscribe: true) }
            + [RoomTestingOptions(clientProtocol: peers.sender, canPublishData: true)]

        try await TestEnvironment.withRooms(options) { rooms in
            let sender = rooms[rooms.count - 1]
            let receivers = Array(rooms.dropLast())

            // The protocol each side reports for the other is the one that side advertised.
            let senderIdentity = try #require(sender.localParticipant.identity)
            for (receiver, advertised) in zip(receivers, peers.receivers) {
                let identity = try #require(receiver.localParticipant.identity)
                #expect(sender.remoteParticipants[identity]?.clientProtocol == advertised ?? .v2)
                #expect(receiver.remoteParticipants[senderIdentity]?.clientProtocol == peers.sender ?? .v2)
            }

            let received = try await Self.receiving(on: receivers, from: sender)
            let packets = try sender.recordDataStreamPackets()

            try await send.perform(payload, topic: "some-topic", from: sender.localParticipant)

            for receiver in received {
                #expect(try await receiver.wait() == payload)
            }
            guard case let .streamHeader(header)? = packets.copy().first?.value else {
                Issue.record("The first packet is not a stream header")
                return
            }
            // Expected from what the sender sees of the participants a broadcast goes to, which is
            // what its registry reports to the core.
            let recipients = Array(sender.remoteParticipants.values)
            #expect(recipients.count == receivers.count)
            let allReadV2 = recipients.allSatisfy { $0.clientProtocol >= .v2 }
            let allDecompress = allReadV2 && recipients.allSatisfy { $0.capabilities.contains(.compressionDeflateRaw) }
            #expect(header.hasInlineContent == (send.mayGoInline && allReadV2))
            if !allDecompress {
                #expect(header.compression.rawValue == Livekit_DataStream_CompressionType.none.rawValue)
            }
        }
    }

    /// A large payload whose compressed form still takes several chunks: a one-shot send goes out
    /// compressed in chunks, a stream in plain chunks, and the receiver reads back what was sent.
    @Test(arguments: Send.allCases)
    func largePayloadRoundTrips(via send: Send) async throws {
        let payload = Self.noisy(200_000)

        try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
            let sender = rooms[1]
            let received = try await Self.receiving(on: [rooms[0]], from: sender)
            let packets = try sender.recordDataStreamPackets()

            try await send.perform(payload, topic: "some-topic", from: sender.localParticipant)

            #expect(try await received[0].wait() == payload)
            let sent = packets.copy()
            guard case let .streamHeader(header)? = sent.first?.value else {
                Issue.record("The first packet is not a stream header")
                return
            }
            let chunks = sent.compactMap { packet -> Data? in
                if case let .streamChunk(chunk)? = packet.value { return chunk.content }
                return nil
            }
            #expect(!header.hasInlineContent)
            #expect(chunks.count > 1)
            let compression: Livekit_DataStream_CompressionType = send.isOneShot ? .deflateRaw : .none
            #expect(header.compression.rawValue == compression.rawValue)
            let wireLength = chunks.reduce(0) { $0 + $1.count }
            #expect(send.isOneShot ? wireLength < payload.count : wireLength == payload.count)
        }
    }

    /// Registers text and byte handlers on each of `rooms` that read a stream from `sender` to the
    /// end, as bytes (UTF-8 for text), and returns one result per room.
    private static func receiving(on rooms: [Room], from sender: Room) async throws -> [AsyncCompleter<Data>] {
        var received: [AsyncCompleter<Data>] = []
        for room in rooms {
            let result = AsyncCompleter<Data>(label: "Stream received", defaultTimeout: 30)
            received.append(result)
            let senderIdentity = sender.localParticipant.identity
            try await room.registerTextStreamHandler(for: "some-topic") { reader, participant in
                #expect(participant == senderIdentity)
                do {
                    try await result.resume(returning: Data(reader.readAll().utf8))
                } catch {
                    result.resume(throwing: error)
                }
            }
            try await room.registerByteStreamHandler(for: "some-topic") { reader, participant in
                #expect(participant == senderIdentity)
                do {
                    try await result.resume(returning: reader.readAll())
                } catch {
                    result.resume(throwing: error)
                }
            }
        }
        return received
    }

    /// ASCII text over 16 letters from a fixed generator: compressible, but to about half its size,
    /// not to a few hundred bytes the way repeated text is.
    private static func noisy(_ count: Int) -> Data {
        var state: UInt32 = 1
        return Data((0 ..< count).map { _ in
            state = state &* 1_103_515_245 &+ 12345
            return UInt8(97 + (state >> 16) % 16)
        })
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
