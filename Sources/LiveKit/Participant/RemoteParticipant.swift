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

public class RemoteParticipant: Participant {

    init(sid: Sid,
         info: Livekit_ParticipantInfo?,
         room: Room) {

        super.init(sid: sid,
                   identity: info?.identity ?? "",
                   name: info?.name ?? "",
                   room: room)

        if let info = info {
            updateFromInfo(info: info)
        }
    }

    internal override func cleanUp() -> Promise<Void> {
        super.cleanUp().then(on: .sdk) {
            self.unpublishAll(shouldNotify: false)
        }
    }

    public func getTrackPublication(sid: Sid) -> RemoteTrackPublication? {
        return _state.tracks[sid] as? RemoteTrackPublication
    }

    override func updateFromInfo(info: Livekit_ParticipantInfo) {
        let hadInfo = self.info != nil
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

        if hadInfo {
            // ensure we are updating only tracks published since joining
            for publication in newTrackPublications.values {
                notify { $0.participant(self, didPublish: publication) }
                room.notify { $0.room(self.room, participant: self, didPublish: publication) }
            }
        }

        let unpublishPromises = _state.tracks.values
            .filter { validTrackPublications[$0.sid] == nil }
            .compactMap { $0 as? RemoteTrackPublication }
            .map { unpublish(publication: $0) }

        // TODO: Return a promise
        unpublishPromises.all(on: .sdk).catch(on: .sdk) { error in
            self.log("Failed to unpublish with error: \(error)")
        }
    }

    func addSubscribedMediaTrack(rtcTrack: RTCMediaStreamTrack, sid: Sid) -> Promise<Void> {
        var track: Track

        guard let publication = getTrackPublication(sid: sid) else {
            log("Could not subscribe to mediaTrack \(sid), unable to locate track publication", .error)
            let error = TrackError.state(message: "Could not find published track with sid: \(sid)")
            notify { $0.participant(self, didFailToSubscribe: sid, error: error) }
            room.notify { $0.room(self.room, participant: self, didFailToSubscribe: sid, error: error) }
            return Promise(error)
        }

        switch rtcTrack.kind {
        case "audio":
            track = RemoteAudioTrack(name: publication.name,
                                     source: publication.source,
                                     track: rtcTrack)
        case "video":
            track = RemoteVideoTrack(name: publication.name,
                                     source: publication.source,
                                     track: rtcTrack)
        default:
            let error = TrackError.type(message: "Unsupported type: \(rtcTrack.kind.description)")
            notify { $0.participant(self, didFailToSubscribe: sid, error: error) }
            room.notify { $0.room(self.room, participant: self, didFailToSubscribe: sid, error: error) }
            return Promise(error)
        }

        publication.set(track: track)
        track._state.mutate { $0.sid = publication.sid }

        addTrack(publication: publication)
        return track.start().then(on: .sdk) { _ -> Void in
            self.notify { $0.participant(self, didSubscribe: publication, track: track) }
            self.room.notify { $0.room(self.room, participant: self, didSubscribe: publication, track: track) }
        }
    }

    public func unpublishAll(shouldNotify: Bool = true) -> Promise<Void> {
        // build a list of promises
        let promises = _state.tracks.values.compactMap { $0 as? RemoteTrackPublication }
            .map { unpublish(publication: $0, shouldNotify: shouldNotify) }
        // combine promises to wait all to complete
        return promises.all(on: .sdk)
    }

    func unpublish(publication: RemoteTrackPublication, shouldNotify: Bool = true) -> Promise<Void> {

        func notifyUnpublish() -> Promise<Void> {
            Promise<Void>(on: .sdk) {
                guard shouldNotify else { return }
                // notify unpublish
                self.notify { $0.participant(self, didUnpublish: publication) }
                self.room.notify { $0.room(self.room, participant: self, didUnpublish: publication) }
            }
        }

        // remove the publication
        _state.mutate { $0.tracks.removeValue(forKey: publication.sid) }

        // continue if the publication has a track
        guard let track = publication.track else {
            // if track is nil, only notify unpublish
            return notifyUnpublish()
        }

        return track.stop().then(on: .sdk) { _ -> Void in
            guard shouldNotify else { return }
            // notify unsubscribe
            self.notify { $0.participant(self, didUnsubscribe: publication, track: track) }
            self.room.notify { $0.room(self.room, participant: self, didUnsubscribe: publication, track: track) }
        }.then(on: .sdk) {
            notifyUnpublish()
        }
    }
}
