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

/// A data track published by a remote participant. Delivered via
/// ``RoomDelegate/room(_:didPublishDataTrack:)`` and available on ``RemoteParticipant/dataTracks``.
/// Call ``subscribe()`` to start receiving frames.
public final class RemoteDataTrack: NSObject, Sendable {
    private let track: LiveKitUniFFI.RemoteDataTrack

    /// Identity of the participant publishing this track.
    @objc public let publisherIdentity: Participant.Identity

    // Both are fixed for the track's lifetime, unlike its SID, which is reassigned when the
    // publisher republishes after a full reconnect. Cached so the hot paths that key on them
    // (the participant's `dataTracks` map, re-attaching parked tracks) don't cross the FFI
    // boundary — some of them under a state lock.
    let name: String

    init(_ track: LiveKitUniFFI.RemoteDataTrack) {
        self.track = track
        publisherIdentity = Participant.Identity(from: track.publisherIdentity())
        name = track.info().name
        super.init()
    }

    /// Whether the track is currently published by the remote participant.
    @objc public var isPublished: Bool { track.isPublished() }

    /// Metadata for this track.
    @objc public var info: DataTrackInfo { DataTrackInfo(track.info()) }

    /// Waits until the track is unpublished, by either the publisher or the SFU.
    @objc public func waitForUnpublish() async {
        await track.waitForUnpublish()
    }

    /// Subscribes to the track and returns a ``DataTrackStream`` of incoming frames.
    ///
    /// Subscribing more than once is allowed: the streams share one pipeline, each receives every
    /// frame from the moment it subscribes (nothing is replayed), and later calls don't change
    /// the buffer size.
    ///
    /// - Parameter bufferSize: Maximum number of received frames buffered internally before the
    ///   oldest is dropped. A value of 0 is clamped to 1. In Objective-C this argument is required.
    /// - Throws: ``DataTrackSubscribeError`` if the subscription cannot be established.
    @objc public func subscribe(bufferSize: UInt32 = 16) async throws -> DataTrackStream {
        do {
            let options = LiveKitUniFFI.DataTrackSubscribeOptions(bufferSize: bufferSize)
            let stream = try await track.subscribeWithOptions(options: options)
            return DataTrackStream(stream)
        } catch let error as LiveKitUniFFI.DataTrackSubscribeError {
            throw DataTrackSubscribeError(error)
        }
    }
}
