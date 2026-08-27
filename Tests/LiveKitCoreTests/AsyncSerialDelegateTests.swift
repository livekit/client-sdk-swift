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

struct AsyncSerialDelegateTests {
    final class Recorder: Sendable {
        let calls = StateSync<[Int]>([])
        func record(_ value: Int) { calls.mutate { $0.append(value) } }
    }

    private func waitForCalls(_ recorder: Recorder, count: Int) async throws {
        let deadline = Date().addingTimeInterval(10)
        while recorder.calls.copy().count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Each batch is delivered in the order given. Only the guarantee is asserted: batches race
    /// each other, so the relative order *within* a batch is what callers can rely on.
    @Test
    func notifyDetachedInOrderDeliversInOrder() async throws {
        let delegate = AsyncSerialDelegate<Recorder>()
        let recorder = Recorder()
        delegate.set(delegate: recorder)

        let batches = 50
        for batch in 0 ..< batches {
            delegate.notifyDetached(inOrder: { $0.record(batch * 2) },
                                    { $0.record(batch * 2 + 1) })
        }

        try await waitForCalls(recorder, count: batches * 2)
        let calls = recorder.calls.copy()
        #expect(calls.count == batches * 2)

        for batch in 0 ..< batches {
            let first = try #require(calls.firstIndex(of: batch * 2), "Missing first call of batch \(batch)")
            let second = try #require(calls.firstIndex(of: batch * 2 + 1), "Missing second call of batch \(batch)")
            #expect(first < second, "Batch \(batch) was delivered out of order")
        }
    }

    /// A batch waits for the previous notification to finish, so a slow one can't be overtaken.
    @Test
    func notifyDetachedInOrderWaitsForSlowNotifications() async throws {
        let delegate = AsyncSerialDelegate<Recorder>()
        let recorder = Recorder()
        delegate.set(delegate: recorder)

        delegate.notifyDetached(inOrder: { recorder in
            try? await Task.sleep(nanoseconds: 300_000_000)
            recorder.record(0)
        }, { $0.record(1) })

        try await waitForCalls(recorder, count: 2)
        #expect(recorder.calls.copy() == [0, 1])
    }

    /// Nothing is delivered once the delegate is gone — it is held weakly.
    @Test
    func notifyDetachedInOrderDropsReleasedDelegate() async throws {
        let delegate = AsyncSerialDelegate<Recorder>()
        let recorder = Recorder()
        do {
            let transient = Recorder()
            delegate.set(delegate: transient)
        }
        delegate.notifyDetached(inOrder: { $0.record(0) }, { $0.record(1) })

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(recorder.calls.copy().isEmpty)
    }
}
