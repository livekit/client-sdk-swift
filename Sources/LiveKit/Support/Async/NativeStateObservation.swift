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

internal import LiveKitFFI

/// Pull-driven immutable values. Each iterator owns its revision and cancellation,
/// with no buffering task. Values may coalesce; ordered delegates use the event cursor.
struct NativeStateObservation<Value: Sendable>: AsyncSequence, Sendable {
    typealias Element = Value
    struct Cursor: Sendable {
        let stateDidChange: @Sendable (UInt64?) async -> Value?
        let cancel: @Sendable () -> Void
    }

    private let make: @Sendable () -> Cursor
    private let revision: @Sendable (Value) -> UInt64

    init(revision: @escaping @Sendable (Value) -> UInt64, make: @escaping @Sendable () -> Cursor) {
        self.revision = revision
        self.make = make
    }

    func makeAsyncIterator() -> Iterator { Iterator(cursor: make(), revision: revision) }

    struct Iterator: AsyncIteratorProtocol {
        let cursor: Cursor
        let revision: @Sendable (Value) -> UInt64
        private var since: UInt64?
        private var finished = false

        fileprivate init(cursor: Cursor, revision: @escaping @Sendable (Value) -> UInt64) {
            self.cursor = cursor
            self.revision = revision
        }

        mutating func next() async throws -> Value? {
            guard !finished else { return nil }
            let since = since
            let cursor = cursor
            // The existing helper defers and joins cancellation outside Swift's
            // cancellation-handler lock, avoiding the pinned UniFFI 0.31 deadlock.
            let value = try await cancellingNative(cursor.cancel) { await cursor.stateDidChange(since) }
            if let value { self.since = revision(value) } else { finished = true }
            return value
        }
    }
}

extension FfiRoom {
    var states: NativeStateObservation<NativeRoomObservation> {
        NativeStateObservation(revision: { $0.revision }) { [self] in
            let observer = observeState()
            return .init(stateDidChange: { await observer.stateDidChange(since: $0) }, cancel: { observer.cancel() })
        }
    }
}

extension FfiParticipant {
    var states: NativeStateObservation<LiveKitFFI.NativeParticipantState> {
        NativeStateObservation(revision: { $0.revision }) { [self] in
            let observer = observeState()
            return .init(stateDidChange: { await observer.stateDidChange(since: $0) }, cancel: { observer.cancel() })
        }
    }
}

extension FfiTrackPublication {
    var states: NativeStateObservation<LiveKitFFI.NativePublicationState> {
        NativeStateObservation(revision: { $0.revision }) { [self] in
            let observer = observeState()
            return .init(stateDidChange: { await observer.stateDidChange(since: $0) }, cancel: { observer.cancel() })
        }
    }
}

extension FfiTrack {
    var states: NativeStateObservation<LiveKitFFI.NativeTrackState> {
        NativeStateObservation(revision: { $0.revision }) { [self] in
            let observer = observeState()
            return .init(stateDidChange: { await observer.stateDidChange(since: $0) }, cancel: { observer.cancel() })
        }
    }
}
