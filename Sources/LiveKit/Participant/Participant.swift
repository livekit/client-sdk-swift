/*
 * Copyright 2022 LiveKit
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
import WebRTC
import Promises

public class Participant: MulticastDelegate<ParticipantDelegate> {

    public let sid: Sid
    public internal(set) var identity: String
    public internal(set) var name: String
    public internal(set) var audioLevel: Float = 0.0
    public internal(set) var isSpeaking: Bool = false {
        didSet {
            guard oldValue != isSpeaking else { return }
            notify { $0.participant(self, didUpdate: self.isSpeaking) }
            // relavent event for Room doesn't exist yet...
        }
    }

    public internal(set) var metadata: String? {
        didSet {
            guard oldValue != metadata else { return }
            notify { $0.participant(self, didUpdate: self.metadata) }
            room.notify { $0.room(self.room, participant: self, didUpdate: self.metadata) }
        }
    }

    public internal(set) var connectionQuality: ConnectionQuality = .unknown {
        didSet {
            guard oldValue != connectionQuality else { return }
            notify { $0.participant(self, didUpdate: self.connectionQuality) }
            room.notify { $0.room(self.room, participant: self, didUpdate: self.connectionQuality) }
        }
    }

    public internal(set) var permissions = ParticipantPermissions()

    public private(set) var joinedAt: Date?
    public internal(set) var tracks = [String: TrackPublication]()

    public var audioTracks: [TrackPublication] {
        tracks.values.filter { $0.kind == .audio }
    }

    public var videoTracks: [TrackPublication] {
        tracks.values.filter { $0.kind == .video }
    }

    internal var info: Livekit_ParticipantInfo?

    // Reference to the Room this Participant belongs to
    public let room: Room

    public init(sid: String,
                identity: String,
                name: String,
                room: Room) {

        self.sid = sid
        self.identity = identity
        self.name = name
        self.room = room
    }

    @discardableResult
    internal func cleanUp() -> Promise<Void> {
        Promise(())
    }

    internal func addTrack(publication: TrackPublication) {
        tracks[publication.sid] = publication
        publication.track?.sid = publication.sid
    }

    internal func updateFromInfo(info: Livekit_ParticipantInfo) {
        self.identity = info.identity
        self.name = info.name
        self.metadata = info.metadata
        self.joinedAt = Date(timeIntervalSince1970: TimeInterval(info.joinedAt))
        self.info = info
        set(permissions: info.permission.toLKType())
    }

    @discardableResult
    internal func set(permissions newValue: ParticipantPermissions) -> Bool {

        guard self.permissions != newValue else {
            // no change
            return false
        }

        self.permissions = newValue
        return true
    }
}

// MARK: - Simplified API

extension Participant {

    public func isCameraEnabled() -> Bool {
        !(getTrackPublication(source: .camera)?.muted ?? true)
    }

    public func isMicrophoneEnabled() -> Bool {
        !(getTrackPublication(source: .microphone)?.muted ?? true)
    }

    public func isScreenShareEnabled() -> Bool {
        !(getTrackPublication(source: .screenShareVideo)?.muted ?? true)
    }

    internal func getTrackPublication(name: String) -> TrackPublication? {
        tracks.values.first(where: { $0.name == name })
    }

    /// find the first publication matching `source` or any compatible.
    internal func getTrackPublication(source: Track.Source) -> TrackPublication? {
        // if source is unknown return nil
        guard source != .unknown else { return nil }
        // try to find a Publication with matching source
        if let result = tracks.values.first(where: { $0.source == source }) {
            return result
        }
        // try to find a compatible Publication
        if let result = tracks.values.filter({ $0.source == .unknown }).first(where: {
            (source == .microphone && $0.kind == .audio) ||
                (source == .camera && $0.kind == .video && $0.name != Track.screenShareVideoName) ||
                (source == .screenShareVideo && $0.kind == .video && $0.name == Track.screenShareVideoName) ||
                (source == .screenShareAudio && $0.kind == .audio && $0.name == Track.screenShareVideoName)
        }) {
            return result
        }

        return nil
    }
}

// MARK: - Equality

public extension Participant {

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(sid)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Participant else {
            return false
        }
        return sid == other.sid
    }
}
