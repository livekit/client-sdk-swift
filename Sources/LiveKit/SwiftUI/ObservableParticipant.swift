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
import SwiftUI
import WebRTC

extension ObservableParticipant: ParticipantDelegate, Loggable {

    public func participant(_ participant: RemoteParticipant,
                            didSubscribe trackPublication: RemoteTrackPublication,
                            track: Track) {
        log("\(self.hashValue) didSubscribe remoteTrack: \(String(describing: track.sid))")
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    public func participant(_ participant: RemoteParticipant,
                            didUnsubscribe trackPublication: RemoteTrackPublication,
                            track: Track) {
        log("\(self.hashValue) didUnsubscribe remoteTrack: \(String(describing: track.sid))")
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    public func participant(_ participant: RemoteParticipant,
                            didUpdate publication: RemoteTrackPublication,
                            permission allowed: Bool) {
        log("\(self.hashValue) didUpdate allowed: \(allowed)")
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    public func localParticipant(_ participant: LocalParticipant,
                                 didPublish trackPublication: LocalTrackPublication) {
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    public func localParticipant(_ participant: LocalParticipant,
                                 didUnpublish trackPublication: LocalTrackPublication) {
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    public func participant(_ participant: Participant,
                            didUpdate trackPublication: TrackPublication,
                            muted: Bool) {
        log("\(self.hashValue) didUpdate muted: \(muted)")
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    public func participant(_ participant: Participant, didUpdate speaking: Bool) {
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    public func participant(_ participant: Participant, didUpdate connectionQuality: ConnectionQuality) {
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
}

extension ObservableParticipant: Identifiable {
    public var id: String {
        participant.sid
    }
}

extension ObservableParticipant: Equatable, Hashable {

    public static func == (lhs: ObservableParticipant, rhs: ObservableParticipant) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension ObservableParticipant {

    public var sid: Sid {
        participant.sid
    }

    public var identity: String {
        participant.identity
    }
}

open class ObservableParticipant: ObservableObject {

    public let participant: Participant

    public var asLocal: LocalParticipant? {
        participant as? LocalParticipant
    }

    public var asRemote: RemoteParticipant? {
        participant as? RemoteParticipant
    }

    public var firstCameraPublication: TrackPublication? {
        participant.videoTracks.first(where: { $0.source == .camera })
    }

    public var firstScreenSharePublication: TrackPublication? {
        participant.videoTracks.first(where: { $0.source == .screenShareVideo })
    }

    public var firstAudioPublication: TrackPublication? {
        participant.audioTracks.first
    }

    public var firstCameraVideoTrack: VideoTrack? {
        guard let pub = firstCameraPublication, !pub.muted, pub.subscribed,
              let track = pub.track else { return nil }
        return track as? VideoTrack
    }

    public var firstScreenShareVideoTrack: VideoTrack? {
        guard let pub = firstScreenSharePublication, !pub.muted, pub.subscribed,
              let track = pub.track else { return nil }
        return track as? VideoTrack
    }

    public var firstAudioTrack: AudioTrack? {
        guard let pub = firstAudioPublication, !pub.muted,
              let track = pub.track else { return nil }
        return track as? AudioTrack
    }

    public var firstVideoAvailable: Bool {
        firstCameraVideoTrack != nil
    }

    public var firstAudioAvailable: Bool {
        firstAudioTrack != nil
    }

    public var isSpeaking: Bool {
        participant.isSpeaking
    }

    public var joinedAt: Date? {
        participant.joinedAt
    }

    public var connectionQuality: ConnectionQuality {
        participant.connectionQuality
    }

    public init(_ participant: Participant) {
        self.participant = participant
        participant.add(delegate: self)
    }
}
