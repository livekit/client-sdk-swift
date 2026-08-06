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
    public func waitForTrack(timeout: TimeInterval = 15) async throws -> RemoteDataTrack {
        guard let track = await Self.first(of: publishStream, timeout: timeout) else {
            throw LiveKitError(.timedOut, message: "Timed out waiting for data track '\(expectedName)'")
        }
        return track
    }

    /// Waits for a data track to be unpublished, returning its SID.
    public func waitForUnpublish(timeout: TimeInterval = 15) async throws -> DataTrack.Sid {
        guard let sid = await Self.first(of: unpublishStream, timeout: timeout) else {
            throw LiveKitError(.timedOut, message: "Timed out waiting for data track unpublish")
        }
        return sid
    }

    /// First element of the stream, or `nil` on timeout.
    private static func first<T: Sendable>(of stream: AsyncStream<T>, timeout: TimeInterval) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                for await element in stream {
                    return element
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
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

/// The eight data-track delegate callbacks, across both delegate protocols and both directions.
public enum DataTrackDelegateEvent: String, Sendable {
    case roomLocalPublish, roomLocalUnpublish
    case roomRemotePublish, roomRemoteUnpublish
    case participantLocalPublish, participantLocalUnpublish
    case participantRemotePublish, participantRemoteUnpublish
}

/// Records data-track delegate events from both ``RoomDelegate`` and ``ParticipantDelegate``.
/// Register on a room and/or a participant before publishing to avoid races.
public final class DataTrackDelegateRecorder: NSObject, RoomDelegate, ParticipantDelegate, @unchecked Sendable {
    private let _events = StateSync<[(DataTrackDelegateEvent, DataTrack.Sid)]>([])

    private func record(_ kind: DataTrackDelegateEvent, _ sid: DataTrack.Sid) {
        _events.mutate { $0.append((kind, sid)) }
    }

    private func firstSid(_ kind: DataTrackDelegateEvent) -> DataTrack.Sid? {
        _events.read { $0.first { $0.0 == kind }?.1 }
    }

    /// Waits for the given event, returning the SID it carried.
    public func waitFor(_ kind: DataTrackDelegateEvent, timeout: TimeInterval = 15) async throws -> DataTrack.Sid {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let sid = firstSid(kind) { return sid }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw LiveKitError(.timedOut, message: "Timed out waiting for delegate event \(kind.rawValue)")
    }

    // MARK: - RoomDelegate

    public func room(_: Room, participant _: LocalParticipant, didPublishDataTrack track: LocalDataTrack) { record(.roomLocalPublish, track.info.sid) }
    public func room(_: Room, participant _: LocalParticipant, didUnpublishDataTrack sid: DataTrack.Sid) { record(.roomLocalUnpublish, sid) }
    public func room(_: Room, participant _: RemoteParticipant, didPublishDataTrack track: RemoteDataTrack) { record(.roomRemotePublish, track.info.sid) }
    public func room(_: Room, participant _: RemoteParticipant, didUnpublishDataTrack sid: DataTrack.Sid) { record(.roomRemoteUnpublish, sid) }

    // MARK: - ParticipantDelegate

    public func participant(_: LocalParticipant, didPublishDataTrack track: LocalDataTrack) { record(.participantLocalPublish, track.info.sid) }
    public func participant(_: LocalParticipant, didUnpublishDataTrack sid: DataTrack.Sid) { record(.participantLocalUnpublish, sid) }
    public func participant(_: RemoteParticipant, didPublishDataTrack track: RemoteDataTrack) { record(.participantRemotePublish, track.info.sid) }
    public func participant(_: RemoteParticipant, didUnpublishDataTrack sid: DataTrack.Sid) { record(.participantRemoteUnpublish, sid) }
}

/// Convenience for simple cases — registers watcher, returns track.
public extension Room {
    func waitForDataTrack(name: String, timeout: TimeInterval = 15) async throws -> RemoteDataTrack {
        let watcher = DataTrackWatcher(expectedName: name)
        delegates.add(delegate: watcher)
        defer { delegates.remove(delegate: watcher) }
        // The publish may have been announced before the watcher registered; checking attached
        // tracks after registration closes the race (an event in between is caught by the watcher).
        for participant in remoteParticipants.values {
            if let track = participant.dataTracks.values.first(where: { $0.info.name == name }) {
                return track
            }
        }
        return try await watcher.waitForTrack(timeout: timeout)
    }
}
