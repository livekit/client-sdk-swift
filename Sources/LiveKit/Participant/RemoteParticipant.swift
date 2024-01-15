/*
 * Copyright 2024 LiveKit
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
    init(info: Livekit_ParticipantInfo, room: Room) {
        super.init(sid: info.sid,
                   identity: info.identity,
                   room: room)

        if identity.isEmpty {
            log("RemoteParticipant.identity is empty", .error)
        }

        updateFromInfo(info: info)
    }

    func getTrackPublication(sid: Sid) -> RemoteTrackPublication? {
        _state.trackPublications[sid] as? RemoteTrackPublication
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
                add(publication: publication!)
            } else {
                publication!.updateFromInfo(info: trackInfo)
            }
            validTrackPublications[trackInfo.sid] = publication!
        }

        room.engine.executeIfConnected { [weak self] in
            guard let self else { return }

            for publication in newTrackPublications.values {
                self.delegates.notify(label: { "participant.didPublish \(publication)" }) {
                    $0.participant?(self, didPublishTrack: publication)
                }
                self.room.delegates.notify(label: { "room.didPublish \(publication)" }) {
                    $0.room?(self.room, participant: self, didPublishTrack: publication)
                }
            }
        }

        let unpublishRemoteTrackPublications = _state.trackPublications.values
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
            log("Could not subscribe to mediaTrack \(sid), unable to locate track publication. existing sids: (\(_state.trackPublications.keys.joined(separator: ", ")))", .error)
            let error = LiveKitError(.invalidState, message: "Could not find published track with sid: \(sid)")
            delegates.notify(label: { "participant.didFailToSubscribe trackSid: \(sid)" }) {
                $0.participant?(self, didFailToSubscribeTrack: sid, withError: error)
            }
            room.delegates.notify(label: { "room.didFailToSubscribe trackSid: \(sid)" }) {
                $0.room?(self.room, participant: self, didFailToSubscribeTrack: sid, withError: error)
            }
            throw error
        }

        switch rtcTrack.kind {
        case "audio":
            track = RemoteAudioTrack(name: publication.name,
                                     source: publication.source,
                                     track: rtcTrack,
                                     reportStatistics: room._state.options.reportRemoteTrackStatistics)
        case "video":
            track = RemoteVideoTrack(name: publication.name,
                                     source: publication.source,
                                     track: rtcTrack,
                                     reportStatistics: room._state.options.reportRemoteTrackStatistics)
        default:
            let error = LiveKitError(.invalidState, message: "Unsupported type: \(rtcTrack.kind.description)")
            delegates.notify(label: { "participant.didFailToSubscribe trackSid: \(sid)" }) {
                $0.participant?(self, didFailToSubscribeTrack: sid, withError: error)
            }
            room.delegates.notify(label: { "room.didFailToSubscribe trackSid: \(sid)" }) {
                $0.room?(self.room, participant: self, didFailToSubscribeTrack: sid, withError: error)
            }
            throw error
        }

        publication.set(track: track)
        publication.set(subscriptionAllowed: true)

        assert(room.engine.subscriber != nil, "Subscriber is nil")
        if let transport = room.engine.subscriber {
            track.set(transport: transport, rtpReceiver: rtpReceiver)
        }

        add(publication: publication)

        try await track.start()

        delegates.notify(label: { "participant.didSubscribe \(publication)" }) {
            $0.participant?(self, didSubscribeTrack: publication)
        }
        room.delegates.notify(label: { "room.didSubscribe \(publication)" }) {
            $0.room?(self.room, participant: self, didSubscribeTrack: publication)
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
        func _notifyUnpublish() async {
            guard _notify else { return }
            delegates.notify(label: { "participant.didUnpublish \(publication)" }) {
                $0.participant?(self, didUnpublishTrack: publication)
            }
            room.delegates.notify(label: { "room.didUnpublish \(publication)" }) {
                $0.room?(self.room, participant: self, didUnpublishTrack: publication)
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
                $0.room?(self.room, participant: self, didUnsubscribeTrack: publication)
            }
        }

        await _notifyUnpublish()
    }
}
