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
/// each framing the core picks for a recipient (inline, compressed, legacy multi-packet) is checked
/// on the wire and read back through the public reader. No network or room is needed.
@Suite(.tags(.dataStream))
struct DataStreamLoopbackTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let testDescription: String
        /// The single recipient's advertised client protocol and compression support.
        let clientProtocol: Int32
        let supportsCompression: Bool
        let text: String
        let isInline: Bool
        let isCompressed: Bool
    }

    static let cases = [
        // Compression needs a v2 recipient too, so a legacy one gets plain chunks either way.
        Case(testDescription: "legacy fallback", clientProtocol: 0, supportsCompression: true,
             text: repetitive(2000), isInline: false, isCompressed: false),
        Case(testDescription: "inline", clientProtocol: 2, supportsCompression: false,
             text: "hello", isInline: true, isCompressed: false),
        Case(testDescription: "inline compressed", clientProtocol: 2, supportsCompression: true,
             text: repetitive(2000), isInline: true, isCompressed: true),
        // Compresses, but not enough to fit in a header packet.
        Case(testDescription: "chunked compressed", clientProtocol: 2, supportsCompression: true,
             text: noisy(200_000), isInline: false, isCompressed: true),
    ]

    @Test(arguments: cases)
    func framingRoundTrips(_ c: Case) async throws {
        let loopback = Loopback(maxPayloadByteLength: nil)
        let outgoing = loopback.outgoing(clientProtocol: c.clientProtocol, supportsCompression: c.supportsCompression)

        _ = try await outgoing.sendText(text: c.text, options: LiveKitFFI.StreamTextOptions(topic: "loopback", attributes: [:]))

        #expect(try await loopback.receiver.read.wait() == c.text)
        let packets = loopback.packets.copy()
        guard case let .streamHeader(header) = packets.first?.value else {
            Issue.record("The first packet is not a stream header")
            return
        }
        #expect(header.hasInlineContent == c.isInline)
        // An inline stream is its header alone; otherwise chunks and a trailer follow it.
        #expect(c.isInline ? packets.count == 1 : packets.count > 2)
        #expect(header.compression.rawValue == (c.isCompressed ? Livekit_DataStream_CompressionType.deflateRaw : .none).rawValue)
    }

    /// The incoming cap holds whatever framing the payload arrived in.
    @Test(arguments: [Int32(0), 2])
    func payloadOverCapFails(clientProtocol: Int32) async throws {
        let loopback = Loopback(maxPayloadByteLength: 1000)
        let outgoing = loopback.outgoing(clientProtocol: clientProtocol, supportsCompression: true)

        _ = try await outgoing.sendText(text: Self.repetitive(5000), options: LiveKitFFI.StreamTextOptions(topic: "loopback", attributes: [:]))

        await #expect(throws: StreamError.lengthExceeded) {
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

    private final class Registry: RemoteParticipantRegistryDelegate, @unchecked Sendable {
        let clientProtocol: Int32
        let capabilities: [LiveKitFFI.ClientCapability]

        init(clientProtocol: Int32, capabilities: [LiveKitFFI.ClientCapability]) {
            self.clientProtocol = clientProtocol
            self.capabilities = capabilities
        }

        func remoteClientProtocol(identity _: String) -> Int32 { clientProtocol }
        func remoteCapabilities(identity _: String) -> [LiveKitFFI.ClientCapability] { capabilities }
        func remoteIdentities() -> [String] { ["peer"] }
    }

    /// Reads the first text stream to open to the end, through the public reader.
    private final class Receiver: IncomingDataStreamManagerDelegate, @unchecked Sendable {
        let read = AsyncCompleter<String>(label: "Loopback read", defaultTimeout: 10)

        func onTextStreamOpened(reader: LiveKitFFI.TextStreamReader, identity _: String) {
            let reader = LiveKit.TextStreamReader(reader, info: LiveKit.TextStreamInfo(reader.info(), encryptionType: .none))
            Task {
                do {
                    try await read.resume(returning: reader.readAll())
                } catch {
                    read.resume(throwing: error)
                }
            }
        }

        func onByteStreamOpened(reader _: LiveKitFFI.ByteStreamReader, identity _: String) {}

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

        func outgoing(clientProtocol: Int32, supportsCompression: Bool) -> OutgoingDataStreamManager {
            let registry = Registry(clientProtocol: clientProtocol, capabilities: supportsCompression ? [.compressionDeflateRaw] : [])
            return OutgoingDataStreamManager(delegate: self, registry: registry)
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
