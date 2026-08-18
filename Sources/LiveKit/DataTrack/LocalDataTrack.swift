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
///
/// The publication follows this object's lifetime: releasing the last reference unpublishes the
/// track, as does calling ``unpublish()``.
public final class LocalDataTrack: NSObject, Sendable {
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
    /// Non-blocking. Throws ``DataTrackPushFrameError/trackUnpublished(_:)`` if the track was
    /// unpublished by the local participant or the SFU, or if the room is no longer connected;
    /// ``DataTrackPushFrameError/queueFull(_:frame:)`` if frames are being pushed faster than they
    /// can be sent, which hands the rejected frame back.
    @objc public func tryPush(frame: DataTrackFrame) throws {
        do {
            try track.tryPush(frame: frame.ffi)
        } catch let error as PushFrameErrorReason {
            throw DataTrackPushFrameError(error, frame: frame)
        } catch {
            // The bindings can't decode the reason a push was rejected — the error type is
            // defined in a different UniFFI component — and report an internal error instead.
            // The call did fail, and only two things cause that, so recover the one that
            // applies rather than leaking an FFI-internal error through the public API.
            throw isPublished
                ? DataTrackPushFrameError.queueFull("The send queue is full", frame: frame)
                : DataTrackPushFrameError.trackUnpublished("The track is no longer published")
        }
    }

    /// Unpublishes the track. Subsequent ``tryPush(frame:)`` calls throw.
    @objc public func unpublish() {
        track.unpublish()
    }

    /// Waits until the track is unpublished, by either the local participant or the SFU.
    ///
    /// Use this to trigger follow-up work once the track is no longer published. Returns
    /// immediately if it is already unpublished.
    @objc public func waitForUnpublish() async {
        await track.waitForUnpublish()
    }
}

// MARK: - Sending an AsyncSequence

/// The slice of a publication the sequence send drives — a seam so the queue-full policy is
/// unit-testable, since saturating a live pipeline to observe it is inherently timing-dependent.
protocol DataTrackFrameSink: AnyObject, Sendable {
    var isPublished: Bool { get }
    func tryPush(frame: DataTrackFrame) throws
}

extension LocalDataTrack: DataTrackFrameSink {}

extension DataTrackFrameSink {
    func sendFrames<S: AsyncSequence>(
        from source: S,
        onQueueFull: LocalDataTrack.FrameDropPolicy,
    ) async throws where S.Element == DataTrackFrame {
        for try await frame in source {
            guard isPublished else { break }
            do {
                try tryPush(frame: frame)
            } catch let error as DataTrackPushFrameError {
                // The track can be unpublished between the check above and the push; end the
                // send as documented rather than surfacing an error.
                if case .trackUnpublished = error { break }
                guard case .queueFull = error else { throw error }
                switch onQueueFull {
                case .throw: throw error
                case .drop: continue
                }
            }
        }
    }
}

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
        try await sendFrames(from: source, onQueueFull: onQueueFull)
    }
}
