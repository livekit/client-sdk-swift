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
        if info != nil {
            updateFromInfo(info: info!)
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
        let publication = getTrackPublication(sid: sid)

        guard publication != nil else {
            if triesLeft == 0 {
                logger.error("could not subscribe to mediaTrack \(sid), unable to locate track publication")
                let err = TrackError.invalidTrackState("Could not find published track with sid: \(sid)")
                delegate?.didFailToSubscribe(sid: sid,
                                             error: err,
                                             participant: self)
                room?.delegate?.didFailToSubscribe(sid: sid,
                                                   error: err,
                                                   participant: self)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.addSubscribedMediaTrack(rtcTrack: rtcTrack, sid: sid, triesLeft: triesLeft - 1)
            }
            return
        }

        switch rtcTrack.kind {
        case "audio":
            track = AudioTrack(rtcTrack: rtcTrack as! RTCAudioTrack, name: publication!.name)
        case "video":
            track = VideoTrack(rtcTrack: rtcTrack as! RTCVideoTrack, name: publication!.name)
        default:
            let err = TrackError.invalidTrackType("unsupported type: \(rtcTrack.kind.description)")
            delegate?.didFailToSubscribe(sid: sid,
                                         error: err,
                                         participant: self)
            room?.delegate?.didFailToSubscribe(sid: sid,
                                               error: err,
                                               participant: self)
            return
        }

        publication!.track = track
        track.sid = publication!.sid
        addTrack(publication: publication!)

        delegate?.didSubscribe(track: track, publication: publication!, participant: self)
        room?.delegate?.didSubscribe(track: track, publication: publication!, participant: self)
    }

    func unpublishTrack(sid: String, sendUnpublish: Bool = false) {
        guard let publication = tracks.removeValue(forKey: sid) as? RemoteTrackPublication else {
            return
        }

        switch publication.kind {
        case .audio:
            audioTracks.removeValue(forKey: sid)
        case .video:
            videoTracks.removeValue(forKey: sid)
        default:
            // ignore
            return
        }

        if publication.track != nil {
            let track = publication.track!
            track.stop()
            delegate?.didUnsubscribe(track: track,
                                     publication: publication,
                                     participant: self)
            room?.delegate?.didUnsubscribe(track: track,
                                           publication: publication,
                                           participant: self)
        }
        if sendUnpublish {
            delegate?.didUnpublishRemoteTrack(publication: publication,
                                              particpant: self)
            room?.delegate?.didUnpublishRemoteTrack(publication: publication,
                                                    particpant: self)
        }
    }

    private func sendTrackPublishedEvent(publication: RemoteTrackPublication) {
        delegate?.didPublishRemoteTrack(publication: publication, participant: self)
        room?.delegate?.didPublishRemoteTrack(publication: publication, participant: self)
    }
}
