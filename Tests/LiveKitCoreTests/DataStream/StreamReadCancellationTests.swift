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
    /// A cancelled caller must not execute close inline. This controlled close records its task's
    /// cancellation state, so the regression fails without deadlocking a native scheduler.
    @Test(arguments: [false, true])
    func closeRunsOutsideTheCancelledCaller(beforeRead: Bool) async throws {
        let entered = AsyncCompleter<Void>(label: "Controlled read entered", defaultTimeout: 5)
        let waiting = AsyncCompleter<Void>(label: "Controlled read waiting", defaultTimeout: 5)
        let closeState = StateSync<(cancelled: Bool?, calls: Int)>((nil, 0))
        let read = Task {
            if beforeRead { withUnsafeCurrentTask { $0?.cancel() } }
            try await StreamError.reading(closingOnCancel: {
                closeState.mutate {
                    $0.cancelled = Task.isCancelled
                    $0.calls += 1
                }
            }) {
                entered.resume(returning: ())
                do {
                    try await waiting.wait()
                } catch {
                    throw LiveKitFFI.DataStreamError.AlreadyClosed
                }
            }
        }
        if !beforeRead {
            try await entered.wait()
            try await within("Controlled cancel returned") {
                withUnsafeCurrentTask { $0?.cancel() }
                read.cancel()
            }
        }
        let result = try await within("Controlled read returned") { await read.result }
        #expect(throws: CancellationError.self) { try result.get() }
        let closed = closeState.copy()
        #expect(closed.cancelled == false)
        #expect(closed.calls == 1)
    }

    /// A manager wake can compete with the reader's close notification on the UniFFI scheduler.
    /// Bound cancellation itself independently, before joining either synchronous native call.
    /// Abort may finish the read before cancellation, with its exact mapped connection error.
    @Test(arguments: Kind.allCases, [false, true])
    func managerWakeRacesReadCancellation(_ kind: Kind, readAll: Bool) async throws {
        for _ in 0 ..< 100 {
            let (capture, manager) = try await openStalledReader(kind)
            let reader = try #require(capture.take())
            let read = Task {
                if readAll {
                    try await reader.readAll()
                } else {
                    try await reader.iterate()
                }
            }
            try await capture.signals.readEntered.wait()
            try await within("Cancel and manager wake returned") {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { read.cancel() }
                    group.addTask { manager.abortAllStreams() }
                    await group.waitForAll()
                }
            }
            let result = try await within("Racing cancelled read returned") { await read.result }
            #expect {
                try result.get()
            } throws: {
                $0 is CancellationError || ($0 as? StreamError) == .abnormalEnd(reason: "Data stream connection closed")
            }
            let open = await manager.openStreamCount()
            #expect(open == 0)
            if case let .failure(error) = result, error is CancellationError {
                await #expect(throws: StreamError.alreadyClosed) { try await reader.readAll() }
            }
        }
    }
}

extension ByteStreamReaderTests {
    /// The native result is produced in a cancelled task. A dispatch controller releases the
    /// synchronous close without needing another cooperative-pool thread (including strict mode).
    @Test(arguments: [false, true])
    func observedCancellationWinsAndJoinsClose(nativeFailure: Bool) async throws {
        let callerReturned = DispatchSemaphore(value: 0)
        let releaseClose = DispatchSemaphore(value: 0)
        let controller = AsyncCompleter<Bool>(label: "Close gate controller", defaultTimeout: 5)
        let closed = StateSync(false)
        let read = Task(priority: .userInitiated) {
            defer { callerReturned.signal() }
            return try await StreamError.reading(closingOnCancel: {
                DispatchQueue.global().async {
                    let returnedEarly = callerReturned.wait(timeout: .now() + 0.05) == .success
                    releaseClose.signal()
                    controller.resume(returning: !returnedEarly)
                }
                let released = releaseClose.wait(timeout: .now() + 5) == .success
                closed.mutate { $0 = released }
            }) {
                withUnsafeCurrentTask { $0?.cancel() }
                if nativeFailure { throw LiveKitFFI.DataStreamError.PayloadTooLarge }
                return Data("discarded".utf8)
            }
        }
        defer { releaseClose.signal() }
        let result = try await within("Cancelled result after close") { await read.result }
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(closed.copy())
        #expect(try await controller.wait())
    }

    @Test(arguments: Kind.allCases)
    func cancelledReadAllOfCompletedEmptyStreamCloses(_ kind: Kind) async throws {
        let id = UUID().uuidString
        let (capture, manager) = try await openStalledReader(kind, streamID: id)
        defer { manager.abortAllStreams() }
        let reader = try #require(capture.take())
        feed(manager) { $0.streamTrailer = Livekit_DataStream.Trailer.with { $0.streamID = id } }
        let open = await manager.openStreamCount()
        #expect(open == 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await reader.readAll()
        }
        let result = try await within("Cancelled empty readAll") { await task.result }
        #expect(throws: CancellationError.self) { try result.get() }
        try await capture.signals.readerClosed.wait()
        await #expect(throws: StreamError.alreadyClosed) { try await reader.readAll() }
    }

    @Test func serialReadsDoNotRetainCompletedPayload() async throws {
        let serial = StreamReadSerialiser()
        let released = AsyncCompleter<Void>(label: "Read payload released", defaultTimeout: 5)
        func readAndRelease() async throws {
            let result = try await serial.run { CallbackLifetime(released: released) }
            withExtendedLifetime(result) {}
        }
        try await readAndRelease()
        try await released.wait()
    }
}

extension ByteStreamReaderTests {
    @Test(arguments: Kind.allCases)
    func readAllKeepsExclusiveConsumptionBetweenChunks(_ kind: Kind) async throws {
        let paused = AsyncCompleter<Void>(label: "Aggregate between chunks", defaultTimeout: 5)
        let release = AsyncCompleter<Void>(label: "Continue aggregation", defaultTimeout: 5)
        let otherEntered = AsyncCompleter<Void>(label: "Another native read entered", defaultTimeout: 5)
        let calls = StateSync(0)
        var signals = Signals()
        signals.beforeNext = {
            let call = calls.mutate { $0 += 1; return $0 }
            if call == 2 {
                paused.resume(returning: ())
                try? await release.wait()
            } else if call > 2 {
                otherEntered.resume(returning: ())
            }
        }
        let id = UUID().uuidString
        let (capture, manager) = try await openStalledReader(kind, streamID: id, signals: signals)
        defer { manager.abortAllStreams(); release.resume(returning: ()) }
        let reader = try #require(capture.take())
        let all = Task { try await reader.readPayload() }
        try await capture.signals.readEntered.wait()
        feed(manager) { $0.streamChunk = Livekit_DataStream.Chunk.with { $0.streamID = id; $0.content = Data("abc".utf8) } }
        try await paused.wait()
        let started = AsyncCompleter<Void>(label: "Iterator started", defaultTimeout: 5)
        let iterator = Task {
            started.resume(returning: ())
            try await reader.iterate()
        }
        try await started.wait()
        // A second consumer must not enter the core while readAll is between native calls.
        await #expect {
            try await otherEntered.wait(timeout: 0.05)
        } throws: { ($0 as? LiveKitError)?.type == .timedOut }
        feed(manager) { $0.streamChunk = Livekit_DataStream.Chunk.with { $0.streamID = id; $0.chunkIndex = 1; $0.content = Data("de".utf8) } }
        feed(manager) { $0.streamTrailer = Livekit_DataStream.Trailer.with { $0.streamID = id } }
        release.resume(returning: ())
        let payload = try await within("Exclusive aggregate completed") { try await all.value }
        #expect(payload == Data("abcde".utf8))
        try await within("Queued iterator completed") { try await iterator.value }
    }
}

extension ByteStreamReaderTests {
    @Test(arguments: Kind.allCases)
    func cancellingQueuedReadClosesActiveAggregate(_ kind: Kind) async throws {
        let (capture, manager) = try await openStalledReader(kind)
        defer { manager.abortAllStreams() }
        let reader = try #require(capture.take())
        let all = Task { try await reader.readAll() }
        try await capture.signals.readEntered.wait()
        let queued = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await reader.iterate()
        }
        let queuedResult = try await within("Queued cancellation completed") { await queued.result }
        #expect(throws: CancellationError.self) { try queuedResult.get() }
        let aggregateResult = try await within("Active aggregate unblocked") { await all.result }
        #expect(throws: StreamError.alreadyClosed) { try aggregateResult.get() }
        let open = await manager.openStreamCount()
        #expect(open == 0)
    }
}
