import Foundation
import WebRTC
import Promises

public class RemoteParticipant: Participant {

    init(sid: String, info: Livekit_ParticipantInfo?) {
        super.init(sid: sid)
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

        for publication in tracks.values where validTrackPublications[publication.sid] == nil {
            if let publication = publication as? RemoteTrackPublication {
                unpublish(publication: publication, shouldNotify: true)
            }
        }
    }

    func addSubscribedMediaTrack(rtcTrack: RTCMediaStreamTrack, sid: String, triesLeft: Int = 20) {
        var track: Track

        guard let publication = getTrackPublication(sid: sid) else {
            if triesLeft == 0 {
                logger.error("could not subscribe to mediaTrack \(sid), unable to locate track publication")
                let err = TrackError.invalidTrackState("Could not find published track with sid: \(sid)")
                notify { $0.participant(self, didFailToSubscribe: sid, error: err) }
                room?.notify { $0.room(self.room!, participant: self, didFailToSubscribe: sid, error: err) }
                return
            }

            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.15) {
                self.addSubscribedMediaTrack(rtcTrack: rtcTrack, sid: sid, triesLeft: triesLeft - 1)
            }
            return
        }

        switch rtcTrack.kind {
        case "audio":
            track = RemoteAudioTrack(rtcTrack: rtcTrack as! RTCAudioTrack, name: publication.name)
        case "video":
            track = RemoteVideoTrack(rtcTrack: rtcTrack as! RTCVideoTrack, name: publication.name)
        default:
            let err = TrackError.invalidTrackType("unsupported type: \(rtcTrack.kind.description)")
            notify { $0.participant(self, didFailToSubscribe: sid, error: err) }
            room?.notify { $0.room(self.room!, participant: self, didFailToSubscribe: sid, error: err) }
            return
        }

        publication.track = track
        track.sid = publication.sid
        addTrack(publication: publication)
        track.start()

        notify { $0.participant(self, didSubscribe: publication, track: track) }
        room?.notify { $0.room(self.room!, participant: self, didSubscribe: publication, track: track) }
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

        return track.stop().then { _ in
            guard shouldNotify else { return }
            // notify unsubscribe
            self.notify { $0.participant(self, didUnsubscribe: publication, track: track) }
            self.room?.notify { $0.room(self.room!, participant: self, didUnsubscribe: publication) }
        }.then {
            notifyUnpublish()
        }
    }
}
