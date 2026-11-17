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

extension ByteStreamReaderTests {
    private enum ObservationContext {
        @TaskLocal static var lifetime: ProgressContext?
    }

    @Test(arguments: Kind.allCases, [false, true])
    func cancelledProgressReleasesTaskLocalsBeforeNativeUpdate(_ kind: Kind, objc: Bool) async throws {
        let registration = StateSync<AsyncCompleter<Void>?>(nil)
        let signals = Signals(onProgressSubscription: { version in
            // Version zero waits for the initial value. Only acknowledge the subsequent stalled wait.
            if version > 0 { registration.copy()?.resume(returning: ()) }
        })
        let (capture, manager) = try await openStalledReader(kind, signals: signals)
        defer { manager.abortAllStreams() }
        let reader = try #require(capture.take())
        let retained = StateSync(0)
        var released: [AsyncCompleter<Void>] = []
        for _ in 0 ..< 1000 {
            let ended = AsyncCompleter<Void>(label: "Observer context released", defaultTimeout: 5)
            released.append(ended)
            let subscribed = AsyncCompleter<Void>(label: "Subscriber registered", defaultTimeout: 5)
            registration.mutate { $0 = subscribed }
            try await observeThenCancel(reader, objc: objc, released: ended, retained: retained, nativeWaiting: capture.signals.progressWaiting, subscribed: subscribed)
        }
        // No chunks, trailer, or close have been sent: cancellation alone must release contexts.
        do {
            for ended in released {
                try await ended.wait()
            }
        } catch {
            Issue.record("Cancelled progress contexts retained before update/close: \(retained.copy()) / 1000")
            throw error
        }
        #expect(retained.copy() == 0)
        #expect(await manager.openStreamCount() == 1)
    }

    private final class ProgressContext: Sendable {
        let released: AsyncCompleter<Void>
        let retained: StateSync<Int>

        init(released: AsyncCompleter<Void>, retained: StateSync<Int>) {
            self.released = released
            self.retained = retained
            retained.mutate { $0 += 1 }
        }

        deinit {
            retained.mutate { $0 -= 1 }
            released.resume(returning: ())
        }
    }

    private func observeThenCancel(_ reader: AnyReader, objc: Bool, released: AsyncCompleter<Void>, retained: StateSync<Int>, nativeWaiting: AsyncCompleter<Void>, subscribed: AsyncCompleter<Void>) async throws {
        let started = AsyncCompleter<Void>(label: "Observer initial progress", defaultTimeout: 5)
        let stopped = AsyncCompleter<Void>(label: "Observer callback released", defaultTimeout: 5)
        if objc {
            ObservationContext.$lifetime.withValue(ProgressContext(released: released, retained: retained)) {
                reader.readProgress { [lifetime = CallbackLifetime(released: stopped)] _ in
                    withExtendedLifetime(lifetime) { started.resume(returning: ()) }
                }
            }
            try await started.wait()
            try await nativeWaiting.wait()
            try await subscribed.wait()
            reader.stopReadingProgress()
            try await stopped.wait()
        } else {
            let task = ObservationContext.$lifetime.withValue(ProgressContext(released: released, retained: retained)) {
                Task {
                    for await _ in reader.progress() {
                        started.resume(returning: ())
                    }
                }
            }
            try await started.wait()
            try await nativeWaiting.wait()
            try await subscribed.wait()
            task.cancel()
            try await within("Observer joined") { await task.value }
        }
    }
}
