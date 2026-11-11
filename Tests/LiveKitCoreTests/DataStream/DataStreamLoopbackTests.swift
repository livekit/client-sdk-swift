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

/// Sends through an outgoing manager whose delegate hands every packet to an incoming manager, so
/// each framing the core picks for its recipients (inline, compressed, legacy multi-packet) is
/// checked on the wire and read back through the public reader. No network or room is needed.
@Suite(.tags(.dataStream))
struct DataStreamLoopbackTests {
    /// What a remote participant advertises: its client protocol and whether it can decompress.
    struct Remote: Sendable {
        let clientProtocol: Int32
        let supportsCompression: Bool

        static let legacy = Remote(clientProtocol: 0, supportsCompression: false)
        static let v2 = Remote(clientProtocol: 2, supportsCompression: true)
        static let v2WithoutCompression = Remote(clientProtocol: 2, supportsCompression: false)
    }

    enum Payload: Sendable {
        case text(String)
        case bytes(Data)

        var data: Data {
            switch self {
            case let .text(text): Data(text.utf8)
            case let .bytes(data): data
            }
        }
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let testDescription: String
        /// The room's remote participants by identity.
        var remotes: [String: Remote] = ["peer": .v2]
        /// Empty for a broadcast to every remote participant.
        var destinations: [String] = []
        let payload: Payload
        var compress = true
        let isInline: Bool
        let isCompressed: Bool
    }

    static let cases = [
        // Compression needs a v2 recipient too, so a legacy one gets plain chunks either way.
        Case(testDescription: "legacy text", remotes: ["peer": .legacy],
             payload: .text(repetitive(2000)), isInline: false, isCompressed: false),
        Case(testDescription: "legacy bytes", remotes: ["peer": .legacy],
             payload: .bytes(Data([0, 1, 2, 3])), isInline: false, isCompressed: false),
        Case(testDescription: "inline text", remotes: ["peer": .v2WithoutCompression],
             payload: .text("hello"), isInline: true, isCompressed: false),
        // Deflate would make it larger, so the raw bytes go inline.
        Case(testDescription: "inline incompressible text",
             payload: .text("short"), isInline: true, isCompressed: false),
        Case(testDescription: "inline text, compression off",
             payload: .text(repetitive(2000)), compress: false, isInline: true, isCompressed: false),
        Case(testDescription: "inline compressed text",
             payload: .text(repetitive(2000)), isInline: true, isCompressed: true),
        // Compresses, but not enough to fit in a header packet.
        Case(testDescription: "chunked compressed text",
             payload: .text(noisy(200_000)), isInline: false, isCompressed: true),
        Case(testDescription: "inline short bytes",
             payload: .bytes(Data([0, 1, 2, 3])), isInline: true, isCompressed: false),
        Case(testDescription: "inline compressed bytes",
             payload: .bytes(Data((0 ..< 500).map { UInt8($0 % 7) })), isInline: true, isCompressed: true),
        Case(testDescription: "chunked compressed bytes",
             payload: .bytes(Data(noisy(200_000).utf8)), isInline: false, isCompressed: true),
        // Eligibility is unanimous: one legacy participant takes a broadcast back to plain chunks.
        Case(testDescription: "mixed room, broadcast", remotes: ["alice": .v2, "bob": .legacy],
             payload: .text(repetitive(2000)), isInline: false, isCompressed: false),
        Case(testDescription: "mixed room, capable recipients", remotes: ["alice": .v2, "carol": .v2, "bob": .legacy],
             destinations: ["alice", "carol"], payload: .text(repetitive(2000)), isInline: true, isCompressed: true),
        Case(testDescription: "mixed room, a recipient without compression",
             remotes: ["alice": .v2, "dave": .v2WithoutCompression, "bob": .legacy],
             destinations: ["alice", "dave"], payload: .text(repetitive(2000)), isInline: true, isCompressed: false),
        Case(testDescription: "mixed room, a legacy recipient", remotes: ["alice": .v2, "bob": .legacy],
             destinations: ["alice", "bob"], payload: .text(repetitive(2000)), isInline: false, isCompressed: false),
        // Nobody in the room could fail to read v2.
        Case(testDescription: "empty room", remotes: [:],
             payload: .text(repetitive(2000)), isInline: true, isCompressed: true),
    ]

    @Test(arguments: cases)
    func framingRoundTrips(_ c: Case) async throws {
        let loopback = Loopback(maxPayloadByteLength: nil)
        let outgoing = loopback.outgoing(remotes: c.remotes)
        let destinations = c.destinations.map { Participant.Identity(from: $0) }

        switch c.payload {
        case let .text(text):
            let options = LiveKit.StreamTextOptions(topic: "loopback", destinationIdentities: destinations, compress: c.compress)
            _ = try await outgoing.sendText(text: text, options: options.ffi)
        case let .bytes(data):
            let options = LiveKit.StreamByteOptions(topic: "loopback", destinationIdentities: destinations, compress: c.compress)
            _ = try await outgoing.sendBytes(data: data, options: options.ffi)
        }

        #expect(try await loopback.receiver.read.wait() == c.payload.data)
        let packets = loopback.packets.copy()
        guard case let .streamHeader(header) = packets.first?.value else {
            Issue.record("The first packet is not a stream header")
            return
        }
        #expect(header.hasInlineContent == c.isInline)
        // An inline stream is its header alone; otherwise chunks and a trailer follow it.
        #expect(c.isInline ? packets.count == 1 : packets.count > 2)
        #expect(header.compression.rawValue == (c.isCompressed ? Livekit_DataStream_CompressionType.deflateRaw : .none).rawValue)
        guard !c.isCompressed else { return }
        // Uncompressed, the payload is on the wire as it was sent.
        let chunks = packets.compactMap { packet -> Data? in
            if case let .streamChunk(chunk) = packet.value { return chunk.content }
            return nil
        }
        #expect((c.isInline ? header.inlineContent : chunks.reduce(Data(), +)) == c.payload.data)
    }

    /// `generated` travels from the public options to the header, and the receiver reads it back
    /// through the public info, along with the MIME type the core declares for text.
    @Test(arguments: [Remote.legacy, .v2])
    func textInfoRoundTrips(remote: Remote) async throws {
        let loopback = Loopback(maxPayloadByteLength: nil)
        let outgoing = loopback.outgoing(remotes: ["peer": remote])

        _ = try await outgoing.sendText(text: "hi", options: LiveKit.StreamTextOptions(topic: "loopback", generated: true).ffi)

        let info = try await loopback.receiver.info.wait()
        #expect(info.generated)
        #expect(info.mimeType == "text/plain")
    }

    /// The incoming cap holds whatever framing the payload arrived in.
    @Test(arguments: [Remote.legacy, .v2])
    func payloadOverCapFails(remote: Remote) async throws {
        let loopback = Loopback(maxPayloadByteLength: 1000)
        let outgoing = loopback.outgoing(remotes: ["peer": remote])

        _ = try await outgoing.sendText(text: Self.repetitive(5000), options: LiveKitFFI.StreamTextOptions(topic: "loopback", attributes: [:]))

        await #expect(throws: StreamError.payloadTooLarge) {
            try await loopback.receiver.read.wait()
        }
    }

    // MARK: - Helpers

    private static func repetitive(_ count: Int) -> String {
        String(repeating: "a", count: count)
    }

    /// Text over 16 letters from a fixed generator: compressible, but not by much.
    private static func noisy(_ count: Int) -> String {
        var state: UInt32 = 1
        return String((0 ..< count).map { _ in
            state = state &* 1_103_515_245 &+ 12345
            return Character(UnicodeScalar(UInt8(97 + (state >> 16) % 16)))
        })
    }

    /// Reports each remote participant's protocol and capabilities by identity, as the room does.
    private final class Registry: RemoteParticipantRegistryDelegate, @unchecked Sendable {
        let remotes: [String: Remote]

        init(remotes: [String: Remote]) {
            self.remotes = remotes
        }

        func remoteClientProtocol(identity: String) -> Int32 {
            remotes[identity]?.clientProtocol ?? 0
        }

        func remoteCapabilities(identity: String) -> [LiveKitFFI.ClientCapability] {
            remotes[identity]?.supportsCompression == true ? [.compressionDeflateRaw] : []
        }

        func remoteIdentities() -> [String] {
            Array(remotes.keys)
        }
    }

    /// Reads the first stream to open to the end, through the public reader, as bytes (UTF-8 for
    /// text).
    private final class Receiver: IncomingDataStreamManagerDelegate, @unchecked Sendable {
        let info = AsyncCompleter<LiveKit.TextStreamInfo>(label: "Loopback open", defaultTimeout: 10)
        let read = AsyncCompleter<Data>(label: "Loopback read", defaultTimeout: 10)

        func onTextStreamOpened(reader: LiveKitFFI.TextStreamReader, identity _: String) {
            let reader = LiveKit.TextStreamReader(reader)
            info.resume(returning: reader.info)
            Task {
                do {
                    try await read.resume(returning: Data(reader.readAll().utf8))
                } catch {
                    read.resume(throwing: error)
                }
            }
        }

        func onByteStreamOpened(reader: LiveKitFFI.ByteStreamReader, identity _: String) {
            let reader = LiveKit.ByteStreamReader(reader)
            Task {
                do {
                    try await read.resume(returning: reader.readAll())
                } catch {
                    read.resume(throwing: error)
                }
            }
        }

        func onStreamClosed(streamId _: String, identity _: String) {}
    }

    /// Hands every packet straight to the incoming manager, and keeps a decoded copy so the test
    /// can inspect the framing.
    private final class Loopback: OutgoingDataStreamManagerDelegate, @unchecked Sendable {
        let receiver = Receiver()
        let incoming: IncomingDataStreamManager
        let packets = StateSync<[Livekit_DataPacket]>([])

        init(maxPayloadByteLength: UInt64?) {
            incoming = IncomingDataStreamManager(delegate: receiver, maxPayloadByteLength: maxPayloadByteLength)
        }

        func outgoing(remotes: [String: Remote]) -> OutgoingDataStreamManager {
            OutgoingDataStreamManager(delegate: self, registry: Registry(remotes: remotes))
        }

        func onPacketsAvailable(packets emitted: [Data]) {
            for data in emitted {
                if let packet = try? Livekit_DataPacket(serializedBytes: data) {
                    packets.mutate { $0.append(packet) }
                }
                incoming.handlePacketReceived(packet: data, encryptionType: .none)
            }
        }
    }
}
