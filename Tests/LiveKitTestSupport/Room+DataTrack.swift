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
import LiveKitUniFFI

/// Watches for a remote data track to be published. Register as a delegate
/// on `room.dataTrackDelegates` **before** the track is published to avoid races.
public final class DataTrackWatcher: DataTrackDelegate, @unchecked Sendable {
    public let expectedName: String
    private let continuation: AsyncStream<RemoteDataTrack>.Continuation
    private let stream: AsyncStream<RemoteDataTrack>

    public init(expectedName: String) {
        self.expectedName = expectedName
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteDataTrack.self)
        self.stream = stream
        self.continuation = continuation
    }

    /// Waits for the expected track to appear, with timeout.
    public func waitForTrack(timeout: TimeInterval = 15) async throws -> RemoteDataTrack {
        let deadline = Date().addingTimeInterval(timeout)
        for await track in stream {
            return track
        }
        throw LiveKitError(.timedOut, message: "Timed out waiting for data track '\(expectedName)'")
    }

    // MARK: - DataTrackDelegate

    public func room(_: Room, didPublishDataTrack track: RemoteDataTrack) {
        if track.info().name == expectedName {
            continuation.yield(track)
            continuation.finish()
        }
    }
}

/// Convenience for simple cases — registers watcher, returns track.
public extension Room {
    func waitForDataTrack(name: String, timeout: TimeInterval = 15) async throws -> RemoteDataTrack {
        let watcher = DataTrackWatcher(expectedName: name)
        dataTrackDelegates.add(delegate: watcher)
        defer { dataTrackDelegates.remove(delegate: watcher) }
        return try await watcher.waitForTrack(timeout: timeout)
    }
}
