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

/// The v2 receive path through the coordinator: single-packet (inline) streams and the checks the
/// readers add on top of the core.
extension IncomingStreamManagerTests {
    enum ReadMode: CaseIterable {
        case bytesReadAll, bytesIterated, textReadAll, textIterated

        var isByte: Bool {
            self == .bytesReadAll || self == .bytesIterated
        }
    }

    /// The core does not compare an inline payload with the length its header declares, so the
    /// readers do when the stream ends: short is `.incomplete`, long is `.lengthExceeded`.
    @Test(arguments: [(3, StreamError.incomplete), (5, nil), (8, .lengthExceeded)], ReadMode.allCases)
    func inlineLengthIsChecked(_ length: (carried: Int, error: StreamError?), mode: ReadMode) async throws {
        let outcome = try readingError(mode)
        feedHeader(streamID: UUID().uuidString, byte: mode.isByte, totalLength: 5, inlineContent: Data(repeating: 0x61, count: length.carried))

        #expect(try await outcome.wait() as? StreamError == length.error)
    }

    /// A byte stream inline in its header arrives whole, raw or DEFLATE-compressed.
    @Test(arguments: [false, true])
    func inlineBytesRoundTrip(compressed: Bool) async throws {
        let payload = Data((0 ..< 500).map { UInt8($0 % 7) })
        let read = try readingByteStreams()
        try feedHeader(streamID: UUID().uuidString, byte: true, totalLength: UInt64(payload.count),
                       inlineContent: compressed ? deflated(payload) : payload, compression: compressed ? .deflateRaw : .none)

        #expect(try await read.wait() == payload)
    }

    /// Text crosses the FFI as strings, so characters of more than one byte must survive, inline
    /// and split over chunks.
    @Test(arguments: [false, true])
    func multibyteTextRoundTrips(inline: Bool) async throws {
        let text = "héllo → 世界 🎉 café"
        let read = try readingTextStreams()
        let streamID = UUID().uuidString
        if inline {
            feedHeader(streamID: streamID, byte: false, totalLength: UInt64(text.utf8.count), inlineContent: Data(text.utf8))
        } else {
            feedHeader(streamID: streamID, byte: false, totalLength: UInt64(text.utf8.count))
            let split = text.index(text.startIndex, offsetBy: 9)
            feedChunk(streamID: streamID, index: 0, content: Data(text[..<split].utf8))
            feedChunk(streamID: streamID, index: 1, content: Data(text[split...].utf8))
            feedTrailer(streamID: streamID, reason: "")
        }

        #expect(try await read.wait() == text)
    }

    /// An inline stream is complete on arrival, so it never counts as open.
    @Test func inlineStreamIsNeverOpen() async throws {
        let read = try readingTextStreams()
        feedHeader(streamID: UUID().uuidString, byte: false, inlineContent: Data("hi".utf8))

        let opened = await coordinator.openStreamCount()
        #expect(opened == 0)
        #expect(try await read.wait() == "hi")
    }

    // MARK: - Helpers

    /// Raw DEFLATE, the wire format of a compressed stream.
    func deflated(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    /// Registers a handler on `topicName` that reads each stream as `mode` says, and resolves with
    /// the error the read threw, or `nil`.
    func readingError(_ mode: ReadMode) throws -> AsyncCompleter<Error?> {
        let outcome = AsyncCompleter<Error?>(label: "Stream read", defaultTimeout: 10)
        let report: @Sendable (() async throws -> Void) async -> Void = { read in
            do {
                try await read()
                outcome.resume(returning: nil)
            } catch {
                outcome.resume(returning: error)
            }
        }
        switch mode {
        case .bytesReadAll:
            try coordinator.registerByteStreamHandler(for: topicName) { reader, _ in await report { _ = try await reader.readAll() } }
        case .bytesIterated:
            try coordinator.registerByteStreamHandler(for: topicName) { reader, _ in await report { for try await _ in reader {} } }
        case .textReadAll:
            try coordinator.registerTextStreamHandler(for: topicName) { reader, _ in await report { _ = try await reader.readAll() } }
        case .textIterated:
            try coordinator.registerTextStreamHandler(for: topicName) { reader, _ in await report { for try await _ in reader {} } }
        }
        return outcome
    }
}
