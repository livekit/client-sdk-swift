//
//  File.swift
//
//
//  Created by Russell D'Sa on 12/9/20.
//

import Foundation
import WebRTC

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
                sendTrackPublishedEvent(publication: publication)
            }
        }

        for publication in tracks.values where validTrackPublications[publication.sid] == nil {
            unpublishTrack(sid: publication.sid, sendUnpublish: true)
        }
    }

    func addSubscribedMediaTrack(rtcTrack: RTCMediaStreamTrack, sid: String, triesLeft: Int = 20) {
        var track: Track
        
        guard let publication = getTrackPublication(sid: sid) else {
            if triesLeft == 0 {
                logger.error("could not subscribe to mediaTrack \(sid), unable to locate track publication")
                let err = TrackError.invalidTrackState("Could not find published track with sid: \(sid)")
                notify { $0.participant(self, didFailToSubscribe: sid, error: err) }
//                room?.notify { $0.didFailToSubscribe(sid: sid, error: err, participant: self) }
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
            track = AudioTrack(rtcTrack: rtcTrack as! RTCAudioTrack, name: publication.name)
        case "video":
            track = VideoTrack(rtcTrack: rtcTrack as! RTCVideoTrack, name: publication.name)
        default:
            let err = TrackError.invalidTrackType("unsupported type: \(rtcTrack.kind.description)")
            notify { $0.participant(self, didFailToSubscribe: sid, error: err) }
//            room?.notify { $0.didFailToSubscribe(sid: sid,
//                                               error: err,
//                                                 participant: self) }
            room?.notify { $0.room(self.room!, participant: self, didFailToSubscribe: sid, error: err) }
            return
        }

        publication.track = track
        track.sid = publication.sid
        addTrack(publication: publication)

        notify { $0.participant(self, didSubscribe: publication, track: track) }
//        room?.notify { $0.didSubscribe(track: track, publication: publication, participant: self) }
        room?.notify { $0.room(self.room!, participant: self, didSubscribe: publication, track: track) }
    }

    func unpublishTrack(sid: String, sendUnpublish: Bool = false) {

        guard let publication = tracks.removeValue(forKey: sid) as? RemoteTrackPublication else {
            return
        }

        if let track = publication.track {
            track.stop()
            notify { $0.participant(self, didUnsubscribe: publication, track: track) }
//            room?.notify { $0.didUnsubscribe(track: track,
//                                           publication: publication,
//                                             participant: self) }
            room?.notify { $0.room(self.room!, participant: self, didUnsubscribe: publication) }
        }
        if sendUnpublish {
            notify { $0.participant(self, didUnpublish: publication) }
            room?.notify { $0.room(self.room!, participant: self, didUnpublish: publication) }
        }
    }

    private func sendTrackPublishedEvent(publication: RemoteTrackPublication) {
        notify { $0.participant(self, didPublish: publication) }
        room?.notify { $0.room(self.room!, participant: self, didPublish: publication) }
    }
}
