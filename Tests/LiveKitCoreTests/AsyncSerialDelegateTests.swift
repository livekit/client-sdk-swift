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

@Suite(.tags(.concurrency))
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

    /// Calls made in sequence are delivered in that sequence.
    @Test
    func deliversInCallOrder() async throws {
        let delegate = AsyncSerialDelegate<Recorder>()
        let recorder = Recorder()
        delegate.set(delegate: recorder)

        let count = 2000
        for value in 0 ..< count {
            delegate.notifyDetached { $0.record(value) }
        }

        try await waitForCalls(recorder, count: count)
        #expect(recorder.calls.copy() == Array(0 ..< count))
    }

    /// A slow notification holds the ones queued after it; nothing overtakes it.
    @Test
    func waitsForSlowNotifications() async throws {
        let delegate = AsyncSerialDelegate<Recorder>()
        let recorder = Recorder()
        delegate.set(delegate: recorder)

        delegate.notifyDetached { recorder in
            try? await Task.sleep(nanoseconds: 300_000_000)
            recorder.record(0)
        }
        delegate.notifyDetached { $0.record(1) }
        delegate.notifyDetached { $0.record(2) }

        try await waitForCalls(recorder, count: 3)
        #expect(recorder.calls.copy() == [0, 1, 2])
    }

    /// Nothing is delivered once the delegate is gone; it is held weakly.
    @Test
    func dropsReleasedDelegate() async throws {
        let delegate = AsyncSerialDelegate<Recorder>()
        let recorder = Recorder()
        do {
            let transient = Recorder()
            delegate.set(delegate: transient)
        }
        delegate.notifyDetached { $0.record(0) }
        delegate.notifyDetached { $0.record(1) }

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(recorder.calls.copy().isEmpty)
    }

    /// Notifications queued before the object is released are still delivered.
    @Test
    func deliversQueueDrainedAfterRelease() async throws {
        let recorder = Recorder()
        do {
            let delegate = AsyncSerialDelegate<Recorder>()
            delegate.set(delegate: recorder)
            for value in 0 ..< 100 {
                delegate.notifyDetached { $0.record(value) }
            }
        }

        try await waitForCalls(recorder, count: 100)
        #expect(recorder.calls.copy() == Array(0 ..< 100))
    }
}
