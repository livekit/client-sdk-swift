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

/// A read that a cancel abandoned still takes a chunk from the core. It must count that chunk
/// before a later read checks the declared length at the end of the stream, or a valid stream
/// fails with `.incomplete`.
@Suite(.tags(.dataStream))
struct StreamReaderAccountingTests {
    /// Each round cancels a read waiting in the core, then reads the rest of an 8-byte stream with
    /// `readAll()`. The core hands the abandoned read its chunk at once, but the stand-in reader
    /// returns it to the SDK only after a few hundred yields, which leaves a later read every chance
    /// to reach the end first. Repeated, because the outcome of a race is what is being tested.
    @Test(arguments: [false, true])
    func cancelledReadIsCountedBeforeTheEnd(byte: Bool) async throws {
        for _ in 0 ..< 20 {
            let capture = Capture()
            let manager = IncomingDataStreamManager(delegate: capture, maxPayloadByteLength: nil)
            let streamID = UUID().uuidString
            feed(manager) {
                $0.streamHeader = Livekit_DataStream.Header.with {
                    $0.streamID = streamID
                    $0.topic = "topic"
                    $0.totalLength = 8
                    $0.contentHeader = byte ? .byteHeader(Livekit_DataStream.ByteHeader()) : .textHeader(Livekit_DataStream.TextHeader())
                }
            }
            let reader = try await capture.opened.wait()

            let read = Task { try await reader.next() }
            try await reader.entered.wait()
            read.cancel()
            let error = try await within("Cancelled read") { await read.result.failure }
            #expect(error is CancellationError)

            for (index, content) in ["abcd", "efgh"].enumerated() {
                feed(manager) {
                    $0.streamChunk = Livekit_DataStream.Chunk.with {
                        $0.streamID = streamID
                        $0.chunkIndex = UInt64(index)
                        $0.content = Data(content.utf8)
                    }
                }
            }
            feed(manager) { $0.streamTrailer = Livekit_DataStream.Trailer.with { $0.streamID = streamID } }

            let rest = try await within("The rest of the stream") { try await reader.readAll() }
            #expect(rest.count == 4)
        }
    }

    // MARK: - Helpers

    /// The public reader of either kind, with the signal from its stand-in core reader.
    struct Reader: Sendable {
        let entered: AsyncCompleter<Void>
        let next: @Sendable () async throws -> Int?
        let readAll: @Sendable () async throws -> Data
    }

    /// Wraps the core's readers in a stand-in that reports when the first read enters the core and,
    /// once the core has answered it, yields a few hundred times before returning the answer.
    private final class Capture: IncomingDataStreamManagerDelegate, @unchecked Sendable {
        let opened = AsyncCompleter<Reader>(label: "Stream opened", defaultTimeout: 10)

        func onByteStreamOpened(reader: LiveKitFFI.ByteStreamReader, identity _: String) {
            let entered = AsyncCompleter<Void>(label: "Read entered the core", defaultTimeout: 5)
            let slow = SlowFirstByteReader(reader, entered: entered)
            let stream = LiveKit.ByteStreamReader(slow, info: LiveKit.ByteStreamInfo(reader.info(), encryptionType: .none))
            opened.resume(returning: Reader(entered: entered, next: {
                var chunks = stream.makeAsyncIterator()
                return try await chunks.next()?.count
            }, readAll: { try await stream.readAll() }))
        }

        func onTextStreamOpened(reader: LiveKitFFI.TextStreamReader, identity _: String) {
            let entered = AsyncCompleter<Void>(label: "Read entered the core", defaultTimeout: 5)
            let slow = SlowFirstTextReader(reader, entered: entered)
            let stream = LiveKit.TextStreamReader(slow, info: LiveKit.TextStreamInfo(reader.info(), encryptionType: .none))
            opened.resume(returning: Reader(entered: entered, next: {
                var chunks = stream.makeAsyncIterator()
                return try await chunks.next()?.utf8.count
            }, readAll: { try await Data(stream.readAll().utf8) }))
        }

        func onStreamClosed(streamId _: String, identity _: String) {}
    }

    private final class SlowFirstByteReader: LiveKitFFI.ByteStreamReaderProtocol {
        private let inner: any LiveKitFFI.ByteStreamReaderProtocol
        private let entered: AsyncCompleter<Void>
        private let calls = StateSync(0)

        init(_ inner: any LiveKitFFI.ByteStreamReaderProtocol, entered: AsyncCompleter<Void>) {
            self.inner = inner
            self.entered = entered
        }

        func info() -> LiveKitFFI.ByteStreamInfo {
            inner.info()
        }

        func next() async throws -> Data? {
            let isFirst = calls.mutate { $0 += 1; return $0 == 1 }
            entered.resume(returning: ())
            let chunk = try await inner.next()
            if isFirst { await yieldAWhile() }
            return chunk
        }

        func readAll() async throws -> Data {
            try await inner.readAll()
        }
    }

    private final class SlowFirstTextReader: LiveKitFFI.TextStreamReaderProtocol {
        private let inner: any LiveKitFFI.TextStreamReaderProtocol
        private let entered: AsyncCompleter<Void>
        private let calls = StateSync(0)

        init(_ inner: any LiveKitFFI.TextStreamReaderProtocol, entered: AsyncCompleter<Void>) {
            self.inner = inner
            self.entered = entered
        }

        func info() -> LiveKitFFI.TextStreamInfo {
            inner.info()
        }

        func next() async throws -> String? {
            let isFirst = calls.mutate { $0 += 1; return $0 == 1 }
            entered.resume(returning: ())
            let chunk = try await inner.next()
            if isFirst { await yieldAWhile() }
            return chunk
        }

        func readAll() async throws -> String {
            try await inner.readAll()
        }
    }

    private func feed(_ manager: IncomingDataStreamManager, _ configure: (inout Livekit_DataPacket.Builder) -> Void) {
        let packet = Livekit_DataPacket.with {
            $0.participantIdentity = "someName"
            configure(&$0)
        }
        guard let data = try? packet.serializedData() else { return }
        manager.handlePacketReceived(packet: data, encryptionType: .none)
    }

    /// Runs `body` in its own task and waits at most 5 s for it, however `body` treats cancellation.
    private func within<T: Sendable>(_ label: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let result = AsyncCompleter<T>(label: label, defaultTimeout: 5)
        Task {
            do {
                try await result.resume(returning: body())
            } catch {
                result.resume(throwing: error)
            }
        }
        return try await result.wait()
    }
}

private func yieldAWhile() async {
    for _ in 0 ..< 500 {
        await Task.yield()
    }
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
