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
