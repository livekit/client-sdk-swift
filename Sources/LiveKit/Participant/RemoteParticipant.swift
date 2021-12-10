import Foundation
import WebRTC
import Promises

public class RemoteParticipant: Participant {

    init(sid: String, info: Livekit_ParticipantInfo?, room: Room) {
        super.init(sid: sid)
        self.room = room
        if let info = info {
            updateFromInfo(info: info)
        }
    }

    public func getTrackPublication(sid: String) -> RemoteTrackPublication? {
        return tracks[sid] as? RemoteTrackPublication
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
                room?.notify { $0.room(self.room!, participant: self, didPublish: publication) }
            }
        }

        let unpublishPromises = tracks.values
            .filter { validTrackPublications[$0.sid] == nil }
            .compactMap { $0 as? RemoteTrackPublication }
            .map { unpublish(publication: $0) }

        // TODO: Return a promise
        _ = all(unpublishPromises)
    }

    func addSubscribedMediaTrack(rtcTrack: RTCMediaStreamTrack, sid: String) -> Promise<Void> {
        var track: Track

        guard let publication = getTrackPublication(sid: sid) else {
            logger.error("Could not subscribe to mediaTrack \(sid), unable to locate track publication")
            let error = TrackError.invalidTrackState("Could not find published track with sid: \(sid)")
            notify { $0.participant(self, didFailToSubscribe: sid, error: error) }
            room?.notify { $0.room(self.room!, participant: self, didFailToSubscribe: sid, error: error) }
            return Promise(error)
        }

        switch rtcTrack.kind {
        case "audio":
            track = RemoteAudioTrack(rtcTrack: rtcTrack as! RTCAudioTrack,
                                     name: publication.name,
                                     source: publication.source)
        case "video":
            track = RemoteVideoTrack(rtcTrack: rtcTrack as! RTCVideoTrack,
                                     name: publication.name,
                                     source: publication.source)
        default:
            let error = TrackError.invalidTrackType("Unsupported type: \(rtcTrack.kind.description)")
            notify { $0.participant(self, didFailToSubscribe: sid, error: error) }
            room?.notify { $0.room(self.room!, participant: self, didFailToSubscribe: sid, error: error) }
            return Promise(error)
        }

        publication.track = track
        track.sid = publication.sid
        addTrack(publication: publication)
        return track.start().then {
            self.notify { $0.participant(self, didSubscribe: publication, track: track) }
            self.room?.notify { $0.room(self.room!, participant: self, didSubscribe: publication, track: track) }
        }
    }

    func unpublish(publication: RemoteTrackPublication, shouldNotify: Bool = true) -> Promise<Void> {

        func notifyUnpublish() -> Promise<Void> {
            Promise<Void> {
                guard shouldNotify else { return }
                // notify unpublish
                self.notify { $0.participant(self, didUnpublish: publication) }
                self.room?.notify { $0.room(self.room!, participant: self, didUnpublish: publication) }
            }
        }

        // remove the publication
        tracks.removeValue(forKey: publication.sid)

        // continue if the publication has a track
        guard let track = publication.track else {
            // if track is nil, only notify unpublish
            return notifyUnpublish()
        }

        return track.stop().always {
            guard shouldNotify else { return }
            // notify unsubscribe
            self.notify { $0.participant(self, didUnsubscribe: publication, track: track) }
            self.room?.notify { $0.room(self.room!, participant: self, didUnsubscribe: publication) }
        }.then {
            notifyUnpublish()
        }
    }

    internal func update(state: Livekit_StreamState, forTrack sid: String) {

        if let trackPublication = tracks[sid] as? RemoteTrackPublication {
            let lkStreamState = state.toLKType()
            trackPublication.streamState = lkStreamState
            notify { $0.participant(self, didUpdate: trackPublication, streamState: lkStreamState) }
            room?.notify { $0.room(self.room!, participant: self, didUpdate: trackPublication, streamState: lkStreamState) }
        }
    }
}
