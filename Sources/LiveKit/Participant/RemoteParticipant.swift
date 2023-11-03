/*
 * Copyright 2023 LiveKit
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

@_implementationOnly import WebRTC

@objc
public class RemoteParticipant: Participant {
    init(sid: Sid,
         info: Livekit_ParticipantInfo?,
         room: Room)
    {
        super.init(sid: sid,
                   identity: info?.identity ?? "",
                   name: info?.name ?? "",
                   room: room)

        if let info {
            updateFromInfo(info: info)
        }
    }

    func getTrackPublication(sid: Sid) -> RemoteTrackPublication? {
        _state.tracks[sid] as? RemoteTrackPublication
    }

    override func updateFromInfo(info: Livekit_ParticipantInfo) {
        super.updateFromInfo(info: info)

        var validTrackPublications = [String: RemoteTrackPublication]()
        var newTrackPublications = [String: RemoteTrackPublication]()

        for trackInfo in info.tracks {
            var publication = getTrackPublication(sid: trackInfo.sid)
            if publication == nil {
                publication = RemoteTrackPublication(info: trackInfo, participant: self)
                newTrackPublications[trackInfo.sid] = publication
                addTrack(publication: publication!)
            } else {
                publication!.updateFromInfo(info: trackInfo)
            }
            validTrackPublications[trackInfo.sid] = publication!
        }

        room.engine.executeIfConnected { [weak self] in
            guard let self else { return }

            for publication in newTrackPublications.values {
                self.delegates.notify(label: { "participant.didPublish \(publication)" }) {
                    $0.participant?(self, didPublish: publication)
                }
                self.room.delegates.notify(label: { "room.didPublish \(publication)" }) {
                    $0.room?(self.room, participant: self, didPublish: publication)
                }
            }
        }

        let unpublishRemoteTrackPublications = _state.tracks.values
            .filter { validTrackPublications[$0.sid] == nil }
            .compactMap { $0 as? RemoteTrackPublication }

        for unpublishRemoteTrackPublication in unpublishRemoteTrackPublications {
            Task {
                do {
                    try await unpublish(publication: unpublishRemoteTrackPublication)
                } catch {
                    log("Failed to unpublish with error: \(error)")
                }
            }
        }
    }

    func addSubscribedMediaTrack(rtcTrack: LKRTCMediaStreamTrack, rtpReceiver: LKRTCRtpReceiver, sid: Sid) async throws {
        let track: Track

        guard let publication = getTrackPublication(sid: sid) else {
            log("Could not subscribe to mediaTrack \(sid), unable to locate track publication. existing sids: (\(_state.tracks.keys.joined(separator: ", ")))", .error)
            let error = TrackError.state(message: "Could not find published track with sid: \(sid)")
            delegates.notify(label: { "participant.didFailToSubscribe trackSid: \(sid)" }) {
                $0.participant?(self, didFailToSubscribe: sid, error: error)
            }
            room.delegates.notify(label: { "room.didFailToSubscribe trackSid: \(sid)" }) {
                $0.room?(self.room, participant: self, didFailToSubscribe: sid, error: error)
            }
            throw error
        }

        switch rtcTrack.kind {
        case "audio":
            track = RemoteAudioTrack(name: publication.name, source: publication.source, track: rtcTrack)
        case "video":
            track = RemoteVideoTrack(name: publication.name, source: publication.source, track: rtcTrack)
        default:
            let error = TrackError.type(message: "Unsupported type: \(rtcTrack.kind.description)")
            delegates.notify(label: { "participant.didFailToSubscribe trackSid: \(sid)" }) {
                $0.participant?(self, didFailToSubscribe: sid, error: error)
            }
            room.delegates.notify(label: { "room.didFailToSubscribe trackSid: \(sid)" }) {
                $0.room?(self.room, participant: self, didFailToSubscribe: sid, error: error)
            }
            throw error
        }

        publication.set(track: track)
        publication.set(subscriptionAllowed: true)

        assert(room.engine.subscriber != nil, "Subscriber is nil")
        if let transport = room.engine.subscriber {
            track.set(transport: transport, rtpReceiver: rtpReceiver)
        }

        addTrack(publication: publication)

        try await track.start()

        delegates.notify(label: { "participant.didSubscribe \(publication)" }) {
            $0.participant?(self, didSubscribe: publication, track: track)
        }
        room.delegates.notify(label: { "room.didSubscribe \(publication)" }) {
            $0.room?(self.room, participant: self, didSubscribe: publication, track: track)
        }
    }

    override func cleanUp(notify _notify: Bool = true) async {
        await super.cleanUp(notify: _notify)

        room.delegates.notify(label: { "room.participantDidLeave" }) {
            $0.room?(self.room, participantDidLeave: self)
        }
    }

    override public func unpublishAll(notify _notify: Bool = true) async {
        // Build a list of Publications
        let publications = _state.tracks.values.compactMap { $0 as? RemoteTrackPublication }
        for publication in publications {
            do {
                try await unpublish(publication: publication, notify: _notify)
            } catch {
                log("Failed to unpublish track \(publication.sid) with error \(error)", .error)
            }
        }
    }

    func unpublish(publication: RemoteTrackPublication, notify _notify: Bool = true) async throws {
        func _notifyUnpublish() async {
            guard _notify else { return }
            delegates.notify(label: { "participant.didUnpublish \(publication)" }) {
                $0.participant?(self, didUnpublish: publication)
            }
            room.delegates.notify(label: { "room.didUnpublish \(publication)" }) {
                $0.room?(self.room, participant: self, didUnpublish: publication)
            }
        }

        // Remove the publication
        _state.mutate { $0.tracks.removeValue(forKey: publication.sid) }

        // Continue if the publication has a track
        guard let track = publication.track else {
            return await _notifyUnpublish()
        }

        try await track.stop()

        if _notify {
            // Notify unsubscribe
            delegates.notify(label: { "participant.didUnsubscribe \(publication)" }) {
                $0.participant?(self, didUnsubscribe: publication, track: track)
            }
            room.delegates.notify(label: { "room.didUnsubscribe \(publication)" }) {
                $0.room?(self.room, participant: self, didUnsubscribe: publication, track: track)
            }
        }

        await _notifyUnpublish()
    }
}
