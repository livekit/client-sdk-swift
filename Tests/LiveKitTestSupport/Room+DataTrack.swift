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

/// Watches for a remote data track to be published/unpublished. Register as a delegate on the
/// room **before** publishing to avoid races.
public final class DataTrackWatcher: NSObject, RoomDelegate, @unchecked Sendable {
    public let expectedName: String

    private let publishStream: AsyncStream<RemoteDataTrack>
    private let publishContinuation: AsyncStream<RemoteDataTrack>.Continuation
    private let unpublishStream: AsyncStream<DataTrack.Sid>
    private let unpublishContinuation: AsyncStream<DataTrack.Sid>.Continuation

    public init(expectedName: String) {
        self.expectedName = expectedName
        (publishStream, publishContinuation) = AsyncStream.makeStream(of: RemoteDataTrack.self)
        (unpublishStream, unpublishContinuation) = AsyncStream.makeStream(of: DataTrack.Sid.self)
        super.init()
    }

    /// Waits for the expected track to be published.
    public func waitForTrack(timeout _: TimeInterval = 15) async throws -> RemoteDataTrack {
        for await track in publishStream {
            return track
        }
        throw LiveKitError(.timedOut, message: "Timed out waiting for data track '\(expectedName)'")
    }

    /// Waits for a data track to be unpublished, returning its SID.
    public func waitForUnpublish(timeout _: TimeInterval = 15) async throws -> DataTrack.Sid {
        for await sid in unpublishStream {
            return sid
        }
        throw LiveKitError(.timedOut, message: "Timed out waiting for data track unpublish")
    }

    // MARK: - RoomDelegate

    public func room(_: Room, participant _: RemoteParticipant, didPublishDataTrack track: RemoteDataTrack) {
        if track.info.name == expectedName {
            publishContinuation.yield(track)
            publishContinuation.finish()
        }
    }

    public func room(_: Room, participant _: RemoteParticipant, didUnpublishDataTrack sid: DataTrack.Sid) {
        unpublishContinuation.yield(sid)
        unpublishContinuation.finish()
    }
}

/// Convenience for simple cases — registers watcher, returns track.
public extension Room {
    func waitForDataTrack(name: String, timeout: TimeInterval = 15) async throws -> RemoteDataTrack {
        let watcher = DataTrackWatcher(expectedName: name)
        delegates.add(delegate: watcher)
        defer { delegates.remove(delegate: watcher) }
        return try await watcher.waitForTrack(timeout: timeout)
    }
}
