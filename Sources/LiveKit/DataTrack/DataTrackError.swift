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

/// An error raised while publishing a ``LocalDataTrack``.
public enum DataTrackPublishError: Error, Sendable {
    /// The participant is not permitted to publish data tracks.
    case notAllowed(String)
    /// A data track with the same name is already published by this participant.
    case duplicateName(String)
    /// The requested track name is invalid.
    case invalidName(String)
    /// The SFU did not respond to the publish request in time.
    case timeout(String)
    /// The maximum number of data tracks for this participant has been reached.
    case limitReached(String)
    /// The connection was lost before the publish completed.
    case disconnected(String)
    /// The track's schema metadata is invalid.
    case invalidSchema(String)
    /// An unexpected internal error occurred.
    case internalError(String)

    init(_ error: PublishError) {
        switch error {
        case let .NotAllowed(message): self = .notAllowed(message)
        case let .DuplicateName(message): self = .duplicateName(message)
        case let .InvalidName(message): self = .invalidName(message)
        case let .Timeout(message): self = .timeout(message)
        case let .LimitReached(message): self = .limitReached(message)
        case let .Disconnected(message): self = .disconnected(message)
        case let .InvalidSchema(message): self = .invalidSchema(message)
        case let .Internal(message): self = .internalError(message)
        @unknown default: self = .internalError(String(describing: error))
        }
    }
}

/// The reason a frame could not be pushed via ``LocalDataTrack/tryPush(frame:)``.
public enum DataTrackPushFrameError: Error, Sendable {
    /// The track has been unpublished, by either the local participant or the SFU.
    case trackUnpublished(String)
    /// The send queue is full; the frame was not enqueued. It is handed back so the caller can
    /// retry or re-queue it rather than losing it.
    case queueFull(String, frame: DataTrackFrame)
    /// An unexpected internal error occurred.
    case internalError(String)

    init(_ error: PushFrameErrorReason, frame: DataTrackFrame) {
        switch error {
        case let .TrackUnpublished(message): self = .trackUnpublished(message)
        case let .QueueFull(message): self = .queueFull(message, frame: frame)
        @unknown default: self = .internalError(String(describing: error))
        }
    }
}

/// An error raised while subscribing to a ``RemoteDataTrack``.
public enum DataTrackSubscribeError: Error, Sendable {
    /// The track was unpublished before the subscription completed.
    case unpublished(String)
    /// The SFU did not respond to the subscribe request in time.
    case timeout(String)
    /// The connection was lost before the subscription completed.
    case disconnected(String)
    /// An unexpected internal error occurred.
    case internalError(String)

    init(_ error: LiveKitUniFFI.DataTrackSubscribeError) {
        switch error {
        case let .Unpublished(message): self = .unpublished(message)
        case let .Timeout(message): self = .timeout(message)
        case let .Disconnected(message): self = .disconnected(message)
        case let .Internal(message): self = .internalError(message)
        @unknown default: self = .internalError(String(describing: error))
        }
    }
}

// MARK: - LocalizedError

// Surfaces the message carried by every case, so `localizedDescription` is meaningful — this is
// all Objective-C sees of these errors (the enums can't be @objc).

extension DataTrackPublishError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .notAllowed(message),
             let .duplicateName(message),
             let .invalidName(message),
             let .timeout(message),
             let .limitReached(message),
             let .disconnected(message),
             let .invalidSchema(message),
             let .internalError(message):
            message
        }
    }
}

extension DataTrackPushFrameError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .trackUnpublished(message),
             let .queueFull(message, _),
             let .internalError(message):
            message
        }
    }
}

extension DataTrackSubscribeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unpublished(message),
             let .timeout(message),
             let .disconnected(message),
             let .internalError(message):
            message
        }
    }
}
