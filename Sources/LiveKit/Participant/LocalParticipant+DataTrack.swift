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

internal import LiveKitUniFFI

// MARK: - Data Track Publishing

public extension LocalParticipant {
    /// Publishes a data track, allowing this participant to send frames to subscribers.
    ///
    /// - Parameter name: Track name visible to other participants. Must be unique per publisher.
    /// - Returns: A ``LocalDataTrack`` used to push frames via ``LocalDataTrack/tryPush(frame:)``.
    /// - Throws: ``DataTrackPublishError`` if the track cannot be published.
    func publishDataTrack(name: String) async throws -> LocalDataTrack {
        guard let manager = _room?.localDataTrackManager else {
            throw LiveKitError(.invalidState, message: "Not connected to a room")
        }
        do {
            let track = try await manager.publishTrack(options: DataTrackOptions(name: name))
            return LocalDataTrack(track)
        } catch let error as PublishError {
            throw DataTrackPublishError(error)
        }
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

    /// Returns metadata for the data tracks currently published by this participant.
    func queryDataTracks() async -> [DataTrackInfo] {
        guard let manager = _room?.localDataTrackManager else { return [] }
        return await manager.queryTracks().map(DataTrackInfo.init)
    }
}
