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

    @Test func delayedEventSnapshotCannotOverwriteObservedRoomValues() async throws {
        let native = FfiRoom()
        let room = Room()
        defer { native.cancel() }
        room.nativeRoom.mutate { $0 = native }
        var stale = LiveKit.NativeRoomState(native.state())
        stale.room = roomInfo(name: "old", count: 1)
        room.applyNativeRoomValues(roomInfo(name: "new", count: 9))
        // Simulate an event invocation queued before the observation, resumed later.
        try room.applyNativeRoomEventValues(#require(stale.room))
        await room.applyNativeSnapshot(stale)
        #expect(room.name == "new")
        #expect(room._state.numParticipants == 9)
        #expect(room._state.maxParticipants == 9)
        room.nativeRoom.mutate { $0 = nil }
    }

    @Test func observedValuesDoNotCoalesceOrderedRecordingDelegates() async throws {
        let watcher = RecordingWatcher()
        let room = Room(delegate: watcher)
        room._state.mutate { $0.connectionState = .connected }
        var info = roomInfo(name: "latest", count: 9)
        info.activeRecording = true
        room.applyNativeRoomValues(info)
        #expect(!room.isRecording)
        for recording in [true, false, true] {
            var event = roomInfo(name: "older", count: 1)
            event.activeRecording = recording
            room.applyNativeRoomEventValues(event)
            room.applyNativeRoomValues(info)
        }
        #expect(try await watcher.completed.wait() == [true, false, true])
        #expect(room.name == "latest")
        #expect(room._state.numParticipants == 9)
    }

    private func roomInfo(name: String, count: UInt32) -> NativeRoomInfo {
        NativeRoomInfo(sid: "RM_test", name: name, metadata: "event metadata", state: .connected,
                       lossyDcOptions: .init(bufferedAmountLowThreshold: 0), reliableDcOptions: .init(bufferedAmountLowThreshold: 0),
                       emptyTimeout: 0, departureTimeout: 0, maxParticipants: count, creationTime: 0,
                       numPublishers: 0, numParticipants: count, activeRecording: false)
    }

    private final class RecordingWatcher: NSObject, RoomDelegate, Sendable {
        let values = StateSync<[Bool]>([])
        let completed = AsyncCompleter<[Bool]>(label: "ordered recording", defaultTimeout: 5)
        func room(_: Room, didUpdateIsRecording isRecording: Bool) {
            let recorded = values.mutate { $0.append(isRecording); return $0 }
            if recorded.count == 3 { completed.resume(returning: recorded) }
        }
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
