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

struct NativeStateObservationTests {
    @Test func independentIteratorsStartImmediatelyAndFinishIndependently() async throws {
        let room = FfiRoom()
        defer { room.cancel() }
        var first = room.states.makeAsyncIterator()
        var second = room.states.makeAsyncIterator()
        let initial = try #require(try await first.next())
        #expect(initial.values.connection == .idle)
        #expect(try await second.next()?.revision == initial.revision)
        room.cancel()
        let terminal = try #require(try await first.next())
        #expect(terminal.terminal)
        #expect(try await second.next()?.terminal == true)
        #expect(try await first.next() == nil)
        #expect(try await second.next() == nil)
        var late = room.states.makeAsyncIterator()
        #expect(try await late.next()?.terminal == true)
    }

    @Test func cancellingOneWaitKeepsRoomAndOtherIteratorAlive() async throws {
        let room = FfiRoom()
        defer { room.cancel() }
        let entered = AsyncCompleter<Void>(label: "state wait entered", defaultTimeout: 5)
        let task = Task {
            var iterator = room.states.makeAsyncIterator()
            _ = try await iterator.next()
            entered.resume(returning: ())
            return try await iterator.next()
        }
        defer { task.cancel() }
        try await entered.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(room.state().connection == .idle)
        var other = room.states.makeAsyncIterator()
        #expect(try await other.next()?.values.connection == .idle)
        room.cancel()
        #expect(try await other.next()?.terminal == true)
    }

    @Test func releasingIteratorReleasesItsNativeObserver() async throws {
        let room = FfiRoom()
        defer { room.cancel() }
        weak var released: NativeRoomObserver?
        var iterator: NativeStateObservation<NativeRoomObservation>.Iterator?
        do {
            let observer = room.observeState()
            released = observer
            let sequence = NativeStateObservation<NativeRoomObservation>(revision: { $0.revision }) {
                .init(stateDidChange: { await observer.stateDidChange(since: $0) }, cancel: { observer.cancel() })
            }
            iterator = sequence.makeAsyncIterator()
        }
        #expect(released != nil)
        #expect(try await iterator?.next()?.values.connection == .idle)
        iterator = nil
        #expect(released == nil)
        #expect(room.state().connection == .idle)
    }

    @Test func contentEqualityIgnoresOrderedEventRevision() {
        let room = FfiRoom()
        defer { room.cancel() }
        var first = LiveKit.NativeRoomState(room.state())
        var second = first
        first.revision = 10
        second.revision = 20
        #expect(first == second)
        second.connection = .connecting
        #expect(first != second)
    }
}
