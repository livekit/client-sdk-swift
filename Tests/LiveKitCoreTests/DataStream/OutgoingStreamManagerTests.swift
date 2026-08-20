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
import LiveKitUniFFI
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
    /// Captures the encoded `DataPacket`s the manager emits.
    private final class CapturingDelegate: OutgoingDataStreamManagerDelegate, @unchecked Sendable {
        let packets = StateSync<[Livekit_DataPacket]>([])

        func onPacketsAvailable(packets emitted: [Data]) {
            for data in emitted {
                guard let packet = try? Livekit_DataPacket(serializedBytes: data) else { continue }
                packets.mutate { $0.append(packet) }
            }
        }
    }

    /// Minimal registry — broadcast with no known remote capabilities.
    private final class StubRegistry: RemoteParticipantRegistryDelegate, @unchecked Sendable {
        func remoteClientProtocol(identity _: String) -> Int32 { 0 }
        func remoteCapabilities(identity _: String) -> [LiveKitUniFFI.ClientCapability] { [] }
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
            options: LiveKitUniFFI.StreamByteOptions(topic: topic, attributes: [:], id: streamID),
        )
        for chunk in testChunks {
            try await writer.write(data: chunk)
        }
        try await writer.close()
        try await settle()

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
            options: LiveKitUniFFI.StreamTextOptions(topic: topic, attributes: [:], id: streamID),
        )
        for chunk in testChunks {
            try await writer.write(text: chunk)
        }
        try await writer.close()
        try await settle()

        assertStream(
            delegate.packets.copy(),
            streamID: streamID,
            topic: topic,
            mimeType: "text/plain",
            expectedPayload: Data(testChunks.reduce("") { $0 + $1 }.utf8),
        )
    }

    @Test func compressMapsToFFIOptions() {
        #expect(LiveKit.StreamTextOptions(topic: "t", compress: true).ffi.compress == true)
        #expect(LiveKit.StreamTextOptions(topic: "t", compress: false).ffi.compress == false)
        #expect(LiveKit.StreamTextOptions(topic: "t").ffi.compress == nil)
        #expect(LiveKit.StreamByteOptions(topic: "t", compress: true).ffi.compress == true)
        #expect(LiveKit.StreamByteOptions(topic: "t").ffi.compress == nil)
    }

    @Test func writerIsOpenReflectsClose() async throws {
        let manager = OutgoingDataStreamManager(delegate: CapturingDelegate(), registry: StubRegistry())
        let ffiWriter = try await manager.streamBytes(
            options: LiveKitUniFFI.StreamByteOptions(topic: "some-topic", attributes: [:]),
        )
        let writer = LiveKit.ByteStreamWriter(ffiWriter, encryptionType: .none)

        var isOpen = await writer.isOpen
        #expect(isOpen == true)

        try await writer.close()
        isOpen = await writer.isOpen
        #expect(isOpen == false)
    }

    // Note: the v1 `errorPropagation` behavior (a data-channel send failure surfacing back to the
    // caller of `write`) is intentionally not ported. The UniFFI outgoing manager decouples the
    // send from transport delivery and does not propagate transport-level send failures.

    // MARK: - Helpers

    private func settle() async throws {
        // Allow any final trailer delivery to reach the capturing delegate.
        try await Task.sleep(nanoseconds: 100_000_000)
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
