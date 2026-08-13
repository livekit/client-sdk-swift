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

// MARK: - Data Track Publishing

public extension LocalParticipant {
    /// Publishes a data track, allowing this participant to send frames to subscribers.
    ///
    /// The publication follows the returned track's lifetime: keep a reference for as long as the
    /// track should stay published — releasing the last reference unpublishes it, as does calling
    /// ``LocalDataTrack/unpublish()``.
    ///
    /// - Parameter name: Track name visible to other participants. Must be unique per publisher.
    /// - Returns: A ``LocalDataTrack`` used to push frames via ``LocalDataTrack/tryPush(frame:)``.
    /// - Throws: ``DataTrackPublishError`` if the track cannot be published.
    func publishDataTrack(name: String) async throws -> LocalDataTrack {
        try await publishDataTrack(name: name, options: nil)
    }

    /// Publishes a data track with options declaring the frames' encoding and schema.
    ///
    /// See ``publishDataTrack(name:)``; the declared metadata is surfaced to subscribers via
    /// ``DataTrackInfo``.
    func publishDataTrack(name: String, options: DataTrackPublishOptions?) async throws -> LocalDataTrack {
        guard let dataTracks = _room?.dataTracks else {
            // Same error Rust reports for a publish on a disconnected room.
            throw DataTrackPublishError.disconnected("Not connected to a room")
        }
        return try await dataTracks.publish(name: name, options: options)
    }

    /// Publishes a data track for the duration of `body`, then unpublishes it automatically.
    ///
    /// - Parameters:
    ///   - name: Track name visible to other participants. Must be unique per publisher.
    ///   - body: Receives the published track; the track is unpublished when it returns or throws.
    /// - Returns: The value returned by `body`.
    func withDataTrack<T>(name: String, body: (LocalDataTrack) async throws -> T) async throws -> T {
        let track = try await publishDataTrack(name: name)
        return try await withTaskCancellationHandler {
            defer { track.unpublish() }
            return try await body(track)
        } onCancel: {
            track.unpublish()
        }
    }
}
