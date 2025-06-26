/*
 * Copyright 2025 LiveKit
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

internal import LiveKitWebRTC

@objc
public class RemoteParticipant: Participant, @unchecked Sendable {
    init(info: Livekit_ParticipantInfo, room: Room, connectionState: ConnectionState) {
        super.init(room: room, sid: Participant.Sid(from: info.sid), identity: Participant.Identity(from: info.identity))
        set(info: info, connectionState: connectionState)
    }

    override func set(info: Livekit_ParticipantInfo, connectionState: ConnectionState) {
        super.set(info: info, connectionState: connectionState)

        var validTrackPublications = [Track.Sid: RemoteTrackPublication]()
        var newTrackPublications = [Track.Sid: RemoteTrackPublication]()

        for trackInfo in info.tracks {
            let trackSid = Track.Sid(from: trackInfo.sid)
            var publication = _state.trackPublications[trackSid] as? RemoteTrackPublication
            if publication == nil {
                publication = RemoteTrackPublication(info: trackInfo, participant: self)
                newTrackPublications[trackSid] = publication
                add(publication: publication!)
            } else {
                publication!.updateFromInfo(info: trackInfo)
            }
            validTrackPublications[trackSid] = publication!
        }

        guard let room = _room else {
            log("_room is nil", .error)
            return
        }

        if case .connected = connectionState {
            for publication in newTrackPublications.values {
                delegates.notify(label: { "participant.didPublish \(publication)" }) {
                    $0.participant?(self, didPublishTrack: publication)
                }
                room.delegates.notify(label: { "room.didPublish \(publication)" }) {
                    $0.room?(room, participant: self, didPublishTrack: publication)
                }
            }
        }

        let unpublishRemoteTrackPublications = _state.trackPublications.values
            .filter { validTrackPublications[$0.sid] == nil }
            .compactMap { $0 as? RemoteTrackPublication }

        for unpublishRemoteTrackPublication in unpublishRemoteTrackPublications {
            Task.detached {
                do {
                    try await self.unpublish(publication: unpublishRemoteTrackPublication)
                } catch {
                    self.log("Failed to unpublish with error: \(error)")
                }
            }
        }
    }

    func addSubscribedMediaTrack(rtcTrack: LKRTCMediaStreamTrack, rtpReceiver: LKRTCRtpReceiver, trackSid: Track.Sid) async throws {
        let room = try requireRoom()
        let track: Track

        guard let publication = trackPublications[trackSid] as? RemoteTrackPublication else {
            log("Could not subscribe to mediaTrack \(trackSid), unable to locate track publication. existing sids: (\(_state.trackPublications.keys.map { String(describing: $0) }.joined(separator: ", ")))", .error)
            let error = LiveKitError(.invalidState, message: "Could not find published track with sid: \(trackSid)")
            delegates.notify(label: { "participant.didFailToSubscribe trackSid: \(trackSid)" }) {
                $0.participant?(self, didFailToSubscribeTrackWithSid: trackSid, error: error)
            }
            room.delegates.notify(label: { "room.didFailToSubscribe trackSid: \(trackSid)" }) {
                $0.room?(room, participant: self, didFailToSubscribeTrackWithSid: trackSid, error: error)
            }
            throw error
        }

        switch rtcTrack.kind {
        case "audio":
            track = RemoteAudioTrack(name: publication.name,
                                     source: publication.source,
                                     track: rtcTrack,
                                     reportStatistics: room._state.roomOptions.reportRemoteTrackStatistics)
        case "video":
            track = RemoteVideoTrack(name: publication.name,
                                     source: publication.source,
                                     track: rtcTrack,
                                     reportStatistics: room._state.roomOptions.reportRemoteTrackStatistics)
        default:
            let error = LiveKitError(.invalidState, message: "Unsupported type: \(rtcTrack.kind.description)")
            delegates.notify(label: { "participant.didFailToSubscribe trackSid: \(trackSid)" }) {
                $0.participant?(self, didFailToSubscribeTrackWithSid: trackSid, error: error)
            }
            room.delegates.notify(label: { "room.didFailToSubscribe trackSid: \(trackSid)" }) {
                $0.room?(room, participant: self, didFailToSubscribeTrackWithSid: trackSid, error: error)
            }
            throw error
        }

        await publication.set(track: track)
        publication.set(subscriptionAllowed: true)

        if let transport = room._state.subscriber {
            await track.set(transport: transport, rtpReceiver: rtpReceiver)
        } else {
            log("Subscriber is nil", .error)
        }

        add(publication: publication)

        try await track.start()

        delegates.notify(label: { "participant.didSubscribe \(publication)" }) {
            $0.participant?(self, didSubscribeTrack: publication)
        }
        room.delegates.notify(label: { "room.didSubscribe \(publication)" }) {
            $0.room?(room, participant: self, didSubscribeTrack: publication)
        }
    }

    override public func unpublishAll(notify _notify: Bool = true) async {
        // Build a list of Publications
        let publications = _state.trackPublications.values.compactMap { $0 as? RemoteTrackPublication }
        for publication in publications {
            do {
                try await unpublish(publication: publication, notify: _notify)
            } catch {
                log("Failed to unpublish track \(publication.sid) with error \(error)", .error)
            }
        }
    }

    func unpublish(publication: RemoteTrackPublication, notify _notify: Bool = true) async throws {
        let room = try requireRoom()

        func _notifyUnpublish() async {
            guard _notify else { return }
            delegates.notify(label: { "participant.didUnpublish \(publication)" }) {
                $0.participant?(self, didUnpublishTrack: publication)
            }
            room.delegates.notify(label: { "room.didUnpublish \(publication)" }) {
                $0.room?(room, participant: self, didUnpublishTrack: publication)
            }
        }

        // Remove the publication
        _state.mutate { $0.trackPublications.removeValue(forKey: publication.sid) }

        // Continue if the publication has a track
        guard let track = publication.track else {
            return await _notifyUnpublish()
        }

        try await track.stop()

        if _notify {
            // Notify unsubscribe
            delegates.notify(label: { "participant.didUnsubscribe \(publication)" }) {
                $0.participant?(self, didUnsubscribeTrack: publication)
            }
            room.delegates.notify(label: { "room.didUnsubscribe \(publication)" }) {
                $0.room?(room, participant: self, didUnsubscribeTrack: publication)
            }
        }

        await _notifyUnpublish()
    }
}
