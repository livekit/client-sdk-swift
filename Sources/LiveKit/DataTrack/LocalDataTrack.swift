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

/// A data track published by the local participant. Obtain one from
/// ``LocalParticipant/publishDataTrack(name:)``, then push frames with ``tryPush(frame:)``.
public final class LocalDataTrack: NSObject, Sendable, FFIBridged {
    private let track: LiveKitUniFFI.LocalDataTrack

    init(_ track: LiveKitUniFFI.LocalDataTrack) {
        self.track = track
        super.init()
    }

    /// Whether the track is currently published. Becomes `false` after ``unpublish()`` or if the
    /// SFU unpublishes it.
    @objc public var isPublished: Bool { track.isPublished() }

    /// Metadata for this track.
    @objc public var info: DataTrackInfo { DataTrackInfo(track.info()) }

    /// Pushes a frame to subscribers.
    ///
    /// Non-blocking. Throws ``DataTrackPushError/trackUnpublished(_:)`` if the track is no longer
    /// published, or ``DataTrackPushError/queueFull(_:)`` if the send queue is saturated.
    @objc public func tryPush(frame: DataTrackFrame) throws {
        do {
            try track.tryPush(frame: frame.ffi)
        } catch let error as PushFrameErrorReason {
            throw DataTrackPushError(error)
        }
    }

    /// Unpublishes the track. Subsequent ``tryPush(frame:)`` calls throw.
    @objc public func unpublish() {
        track.unpublish()
    }

    /// Waits until the track is unpublished, by either the local participant or the SFU.
    @objc public func waitForUnpublish() async {
        await track.waitForUnpublish()
    }
}

// MARK: - Sending an AsyncSequence

public extension LocalDataTrack {
    /// Policy for ``send(contentsOf:onQueueFull:)`` when the send queue is full.
    enum FrameDropPolicy: Sendable {
        /// Propagate the error to the caller.
        case `throw`
        /// Silently skip the frame.
        case drop
    }

    /// Sends frames from `source` until it ends or the track is unpublished.
    ///
    /// - Parameter onQueueFull: How to handle a full send queue. Defaults to ``FrameDropPolicy/drop``.
    func send<S: AsyncSequence>(
        contentsOf source: S,
        onQueueFull: FrameDropPolicy = .drop,
    ) async throws where S.Element == DataTrackFrame {
        for try await frame in source {
            guard isPublished else { break }
            do {
                try tryPush(frame: frame)
            } catch let error as DataTrackPushError {
                guard case .queueFull = error else { throw error }
                switch onQueueFull {
                case .throw: throw error
                case .drop: continue
                }
            }
        }
    }
}
