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

    /// Stores the definition of a data track schema, making it available to subscribers.
    ///
    /// Define a schema before publishing any data track that references it, so subscribers can
    /// resolve it by ID via ``getSchema(_:publishedBy:)``. Treat a definition as write-once —
    /// whether redefining an existing one is rejected is up to the server.
    ///
    /// - Parameters:
    ///   - id: Identifies the schema; the same ID goes into ``DataTrackPublishOptions``.
    ///   - definition: The definition, stored as-is. It is neither parsed nor validated against
    ///     its ``DataTrackSchemaId/encoding``, so it's up to the caller to keep it well-formed.
    /// - Throws: ``LiveKitError`` if the room is disconnected or the server rejects the schema.
    func defineSchema(_ id: DataTrackSchemaId, definition: String) async throws {
        guard let room = _room else {
            throw LiveKitError(.invalidState, message: "Not connected to a room")
        }
        try await room.signalClient.sendStoreDataBlob(key: id.blobKey, contents: Data(definition.utf8))
    }

    /// Retrieves the definition a participant ``defineSchema(_:definition:)``'d for a schema its
    /// data tracks reference.
    ///
    /// - Parameters:
    ///   - id: Identifies the schema, as carried by ``DataTrackInfo/schema``.
    ///   - participant: Identity of the participant that defined it.
    /// - Throws: ``LiveKitError`` if the room is disconnected, no such schema was defined, or the
    ///   stored definition is not valid UTF-8.
    func getSchema(_ id: DataTrackSchemaId, publishedBy participant: Participant.Identity) async throws -> String {
        guard let room = _room else {
            throw LiveKitError(.invalidState, message: "Not connected to a room")
        }
        let contents = try await room.signalClient.sendGetDataBlob(key: id.blobKey,
                                                                   participantIdentity: participant.stringValue)
        guard let definition = String(data: contents, encoding: .utf8) else {
            throw LiveKitError(.failedToConvertData, message: "Schema definition is not valid UTF-8")
        }
        return definition
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
