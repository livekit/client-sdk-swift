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

extension LocalParticipant {
    /// Publishes a data track with the given name.
    ///
    /// - Parameter name: Track name visible to other participants. Must be unique per publisher.
    /// - Returns: A ``LocalDataTrack`` that can be used to push frames to subscribers.
    /// - Throws: ``PublishError`` if the track cannot be published.
    func publishDataTrack(name: String) async throws -> LocalDataTrack {
        guard let manager = _room?.localDataTrackManager else {
            throw LiveKitError(.invalidState, message: "Not connected to a room")
        }
        return try await manager.publishTrack(options: DataTrackOptions(name: name))
    }

    /// Publishes a data track for the duration of the given closure, then unpublishes automatically.
    ///
    /// - Parameters:
    ///   - name: Track name visible to other participants.
    ///   - body: Closure that receives the published track. The track is unpublished when the closure returns or throws.
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

// MARK: - Frame Drop Policy

enum FrameDropPolicy {
    /// Propagate the error to the caller.
    case `throw`
    /// Silently skip the frame.
    case drop
}

// MARK: - Sending AsyncSequence to a Track

extension LocalDataTrack {
    /// Sends frames from the source until it ends or the track is unpublished.
    func send<S: AsyncSequence>(
        contentsOf source: S,
        onQueueFull: FrameDropPolicy = .drop
    ) async throws where S.Element == DataTrackFrame {
        for try await frame in source {
            guard isPublished() else { break }
            do {
                try tryPush(frame: frame)
            } catch PushFrameErrorReason.QueueFull {
                switch onQueueFull {
                case .throw: throw PushFrameErrorReason.QueueFull
                case .drop: continue
                }
            }
        }
    }
}
