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

struct PullTests {
    @Test(arguments: [false, true])
    func cancellationClosesOnceAndJoins(preCancelled: Bool) async throws {
        let entered = AsyncCompleter<Void>(label: "Pull entered", defaultTimeout: 5)
        let finished = AsyncCompleter<Bool>(label: "Pull finished", defaultTimeout: 5)
        let pending = StateSync<CheckedContinuation<Int?, Never>?>(nil)
        let closes = StateSync(0)
        let closed = StateSync(false)
        let pull = Pull<Int>({
            await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
                pending.mutate { waiter in
                    if closes.copy() > 0 { continuation.resume(returning: nil) } else { waiter = continuation }
                }
                entered.resume(returning: ())
            }
        }, cancel: {
            // Resume the read before finishing close, to exercise the join after native wakeup.
            pending.mutate { waiter in
                closes.mutate { $0 += 1 }
                waiter?.resume(returning: nil)
                waiter = nil
            }
            closed.mutate { $0 = true }
        })
        let task = Task {
            if preCancelled { withUnsafeCurrentTask { $0?.cancel() } }
            do {
                _ = try await pull.next()
                finished.resume(returning: false)
            } catch {
                finished.resume(returning: error is CancellationError && closes.copy() == 1 && closed.copy())
            }
        }
        defer { task.cancel() }
        try await entered.wait()
        task.cancel()
        #expect(try await finished.wait())
        await task.value
        #expect(closes.copy() == 1)
    }

    @Test func earlyExitContinuesSameCursorAndEOFDoesNotCancel() async throws {
        let values = StateSync([1, 2])
        let closes = StateSync(0)
        let pull = Pull<Int>({ values.mutate { $0.isEmpty ? nil : $0.removeFirst() } }, cancel: {
            closes.mutate { $0 += 1 }
        })
        for try await value in pull {
            #expect(value == 1)
            break
        }
        #expect(closes.copy() == 0)
        var remaining: [Int] = []
        for try await value in pull {
            remaining.append(value)
        }
        #expect(remaining == [2])
        #expect(try await pull.next() == nil)
        #expect(closes.copy() == 0)
    }

    @Test func domainErrorPassesThrough() async {
        let pull = Pull<Int>({ throw NativeSessionError.Overflow(items: 1, bytes: 1) }, cancel: {})
        await #expect(throws: NativeSessionError.Overflow(items: 1, bytes: 1)) { try await pull.next() }
    }

    @Test func replacingNativeCursorEndsPreviousOwner() async throws {
        let session = NativeRoomSession()
        let first = session.events(options: .init())
        let second = session.events(options: .init())
        defer { second.cancel(); session.cancel() }
        await #expect(throws: NativeSessionError.Cancelled) {
            try await Pull {
                try await first.next()
            } cancel: {
                first.cancel()
            }.next()
        }
    }
}
