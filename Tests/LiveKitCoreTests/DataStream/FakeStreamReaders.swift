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

/// In-memory stand-in for a core stream, replacing the removed packet-fed manager. Holds queued
/// chunks until a read takes them, then ends normally (empty reason), abnormally (non-empty reason),
/// or stays open while `endReason` is `nil`. Like the core, a pending call ignores Swift cancellation
/// and wakes on `close()`.
final class FakeStreamCore<Chunk: Sendable>: Sendable {
    private struct State {
        var chunks: [Chunk]
        var endReason: String?
        var closed = false
        var processed: UInt64 = 0
        var reported: UInt64?
    }

    private let state: StateSync<State>
    private let size: @Sendable (Chunk) -> Int

    init(chunks: [Chunk], endReason: String?, size: @escaping @Sendable (Chunk) -> Int) {
        state = StateSync(State(chunks: chunks, endReason: endReason))
        self.size = size
        state.mutate { s in s.processed = UInt64(chunks.map(size).reduce(0, +)) }
    }

    func push(_ chunk: Chunk) {
        state.mutate { $0.chunks.append(chunk); $0.processed += UInt64(size(chunk)) }
    }

    func finish(reason: String = "") { state.mutate { if $0.endReason == nil { $0.endReason = reason } } }
    func close() { state.mutate { $0.closed = true } }

    /// 1 while the stream is neither closed by its reader nor ended by its sender.
    func openStreamCount() async -> Int {
        state.read { $0.closed || $0.endReason != nil ? 0 : 1 }
    }

    /// Ends every open read abnormally, as a disconnect did.
    func abortAllStreams() { finish(reason: "aborted") }

    func next() async throws -> Chunk? {
        while true {
            let (chunk, closed, end) = state.mutate { ($0.chunks.isEmpty ? nil : $0.chunks.removeFirst(), $0.closed, $0.endReason) }
            if closed { throw DataStreamError.AlreadyClosed }
            if let chunk { return chunk }
            if let end { if end.isEmpty { return nil } else { throw DataStreamError.AbnormalEnd(reason: end) } }
            await Self.pause()
        }
    }

    func nextProgress() async -> LiveKitFFI.StreamProgress? {
        while true {
            let update: LiveKitFFI.StreamProgress?? = state.mutate {
                if !$0.closed, $0.reported == nil || $0.processed > ($0.reported ?? 0) {
                    $0.reported = $0.processed
                    return .some(LiveKitFFI.StreamProgress(bytesProcessed: $0.processed, bytesTotal: nil))
                }
                return $0.closed || $0.endReason != nil ? .some(nil) : nil
            }
            if let update { return update }
            await Self.pause()
        }
    }

    /// A 5 ms wait that, like an FFI call, does not end early on cancellation.
    private static func pause() async {
        await withCheckedContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { c.resume() } }
    }
}

final class FakeByteReader: ByteStreamReaderProtocol {
    let core: FakeStreamCore<Data>
    private let streamInfo: LiveKitFFI.ByteStreamInfo

    init(info: LiveKitFFI.ByteStreamInfo, chunks: [Data], endReason: String?) {
        streamInfo = info
        core = FakeStreamCore(chunks: chunks, endReason: endReason, size: { $0.count })
    }

    init(sharing core: FakeStreamCore<Data>, info: LiveKitFFI.ByteStreamInfo) {
        streamInfo = info
        self.core = core
    }

    func close() { core.close() }
    func info() -> LiveKitFFI.ByteStreamInfo { streamInfo }
    func next() async throws -> Data? { try await core.next() }
    func nextProgress() async -> LiveKitFFI.StreamProgress? { await core.nextProgress() }
    func waitClosed() async {}

    func readAll() async throws -> Data {
        var data = Data()
        while let chunk = try await core.next() {
            data += chunk
        }
        return data
    }
}

final class FakeTextReader: TextStreamReaderProtocol {
    let core: FakeStreamCore<String>
    private let streamInfo: LiveKitFFI.TextStreamInfo

    init(info: LiveKitFFI.TextStreamInfo, chunks: [String], endReason: String?) {
        streamInfo = info
        core = FakeStreamCore(chunks: chunks, endReason: endReason, size: { $0.utf8.count })
    }

    init(sharing core: FakeStreamCore<String>, info: LiveKitFFI.TextStreamInfo) {
        streamInfo = info
        self.core = core
    }

    func close() { core.close() }
    func info() -> LiveKitFFI.TextStreamInfo { streamInfo }
    func next() async throws -> String? { try await core.next() }
    func nextProgress() async -> LiveKitFFI.StreamProgress? { await core.nextProgress() }
    func waitClosed() async {}

    func readAll() async throws -> String {
        var text = ""
        while let chunk = try await core.next() {
            text += chunk
        }
        return text
    }
}

/// The test's handle on a stalled stream's core, in place of the removed manager.
struct StalledCore: Sendable {
    let push: @Sendable (Data) -> Void
    let finish: @Sendable () -> Void
    let count: @Sendable () async -> Int
    let abort: @Sendable () -> Void

    func openStreamCount() async -> Int { await count() }
    func abortAllStreams() { abort() }
}
