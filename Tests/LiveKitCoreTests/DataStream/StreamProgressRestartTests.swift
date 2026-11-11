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

extension ByteStreamReaderTests {
    /// The controlled source suspends the second native call before cancellation, without sleeps.
    /// Also exercise the same restart against the shipped core's real progress iterator.
    @Test(arguments: Kind.allCases, [false, true].flatMap { objc in [false, true].map { (objc, $0) } })
    func progressRestartReplaysFinalUpdate(_ kind: Kind, mode: (Bool, Bool)) async throws {
        let (objc, controlled) = mode
        let source = ControlledProgress()
        var signals = Signals()
        if controlled { signals.progressOverride = { await source.next() } }
        let id = UUID().uuidString
        let (capture, manager) = try await openStalledReader(kind, streamID: id, signals: signals)
        defer { manager.abortAllStreams() }
        let reader = try #require(capture.take())
        let stopped = AsyncCompleter<Void>(label: "Old observer released", defaultTimeout: 5)
        let observe: @Sendable () async -> Void = {
            for await _ in reader.progress() {}
        }
        let first = objc ? nil : Task { await observe() }
        if objc {
            reader.readProgress { [lifetime = CallbackLifetime(released: stopped)] _ in
                withExtendedLifetime(lifetime) {}
            }
        }
        if controlled {
            try await source.waiting.wait()
        } else {
            try await capture.signals.progressWaiting.wait()
        }
        if objc {
            reader.stopReadingProgress()
            try await stopped.wait()
        } else {
            first?.cancel()
            try await within("First progress cancelled") { await first?.value }
        }

        // Finish while the old observer is gone. Both a replacement and a later observer after
        // EOF must get the final cached value. No observer owns the public reader through ObjC.
        if controlled {
            source.final.resume(returning: LiveKitFFI.StreamProgress(bytesProcessed: 5, bytesTotal: 5))
        } else {
            feed(manager) { $0.streamChunk = Livekit_DataStream.Chunk.with { $0.streamID = id; $0.content = Data("abcde".utf8) } }
            feed(manager) { $0.streamTrailer = Livekit_DataStream.Trailer.with { $0.streamID = id } }
        }
        for _ in 0 ..< 2 {
            let updates = try await collectProgress(reader, objc: objc)
            #expect(updates.last == 5)
        }
        if controlled {
            #expect(source.state.copy().calls == 3)
            #expect(source.state.copy().maximum == 1)
        }
    }

    @Test(arguments: Kind.allCases)
    func objcProgressCallbackCanStopAndReplaceItself(_ kind: Kind) async throws {
        let source = ControlledProgress()
        let signals = Signals(progressOverride: { await source.next() })
        let (capture, manager) = try await openStalledReader(kind, signals: signals)
        defer { manager.abortAllStreams() }
        let reader = try #require(capture.take())
        let replaced = AsyncCompleter<Void>(label: "Reentrant replacement", defaultTimeout: 5)
        let ended = AsyncCompleter<Void>(label: "Reentrant observation ended", defaultTimeout: 5)
        let updates = StateSync<[Int]>([])
        reader.readProgress { _ in
            reader.stopReadingProgress()
            reader.readProgress { [lifetime = CallbackLifetime(released: ended)] progress in
                withExtendedLifetime(lifetime) { updates.mutate { $0.append(progress.bytesProcessed) } }
            }
            replaced.resume(returning: ())
        }
        try await replaced.wait()
        try await source.waiting.wait()
        source.final.resume(returning: LiveKitFFI.StreamProgress(bytesProcessed: 5, bytesTotal: 5))
        try await ended.wait()
        #expect(updates.copy().last == 5)
        #expect(source.state.copy().maximum == 1)
    }

    private func collectProgress(_ reader: AnyReader, objc: Bool) async throws -> [Int] {
        let updates = StateSync<[Int]>([])
        if objc {
            let ended = AsyncCompleter<Void>(label: "Replacement ended", defaultTimeout: 5)
            reader.readProgress { [lifetime = CallbackLifetime(released: ended)] update in
                withExtendedLifetime(lifetime) { updates.mutate { $0.append(update.bytesProcessed) } }
            }
            try await ended.wait()
        } else {
            try await within("Replacement progress ended") {
                for await update in reader.progress() {
                    updates.mutate { $0.append(update.bytesProcessed) }
                }
            }
        }
        return updates.copy()
    }

    final class CallbackLifetime: Sendable {
        let released: AsyncCompleter<Void>

        init(released: AsyncCompleter<Void>) {
            self.released = released
        }

        deinit {
            released.resume(returning: ())
        }
    }

    final class ControlledProgress: Sendable {
        let waiting = AsyncCompleter<Void>(label: "Native progress pending", defaultTimeout: 5)
        let final = AsyncCompleter<LiveKitFFI.StreamProgress?>(label: "Native final progress", defaultTimeout: 5)
        let state = StateSync((calls: 0, active: 0, maximum: 0))

        func next() async -> LiveKitFFI.StreamProgress? {
            let call = state.mutate {
                $0.calls += 1
                $0.active += 1
                $0.maximum = max($0.maximum, $0.active)
                return $0.calls
            }
            defer { state.mutate { $0.active -= 1 } }
            if call == 1 { return LiveKitFFI.StreamProgress(bytesProcessed: 0, bytesTotal: 5) }
            if call == 2 {
                waiting.resume(returning: ())
                return try? await final.wait()
            }
            return nil
        }
    }
}
