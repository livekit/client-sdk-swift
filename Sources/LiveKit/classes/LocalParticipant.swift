//
//  LocalParticipant.swift
//
//
//  Created by Russell D'Sa on 12/9/20.
//

import Foundation
import Promises
import WebRTC

public class LocalParticipant: Participant {
    private var streamId = "stream"

    public var localAudioTrackPublications: [TrackPublication] { Array(audioTracks.values) }
    public var localVideoTrackPublications: [TrackPublication] { Array(videoTracks.values) }
    weak var engine: RTCEngine?

    convenience init(fromInfo info: Livekit_ParticipantInfo, engine: RTCEngine, room: Room) {
        self.init(sid: info.sid)
        updateFromInfo(info: info)
        self.engine = engine
        self.room = room
    }

    public func getTrackPublication(sid: String) -> LocalTrackPublication? {
        return tracks[sid] as? LocalTrackPublication
    }

    /// publish a new audio track to the Room
    public func publishAudioTrack(track: LocalAudioTrack,
                                  options _: LocalAudioTrackPublishOptions? = nil) -> Promise<LocalTrackPublication>
    {
        return Promise<LocalTrackPublication> { fulfill, reject in
            if self.localAudioTrackPublications.first(where: { $0.track === track }) != nil {
                reject(TrackError.publishError("This track has already been published."))
                return
            }

            do {
                try self.ensureAudioCategory()
            } catch {
                reject(error)
                return
            }

            let cid = track.mediaTrack.trackId
            do {
                try self.engine?.addTrack(cid: cid, name: track.name, kind: .audio)
                    .then { trackInfo in
                        let transInit = RTCRtpTransceiverInit()
                        transInit.direction = .sendOnly
                        transInit.streamIds = [self.streamId]

                        let transceiver = self.engine?.publisher?.peerConnection.addTransceiver(with: track.mediaTrack, init: transInit)
                        if transceiver == nil {
                            reject(TrackError.publishError("Nil sender returned from peer connection."))
                            return
                        }

                        let publication = LocalTrackPublication(info: trackInfo, track: track, participant: self)
                        self.addTrack(publication: publication)
                        fulfill(publication)
                    }
            } catch {
                reject(error)
            }
        }
    }

    /// publish a new video track to the Room
    public func publishVideoTrack(track: LocalVideoTrack,
                                  options: LocalVideoTrackPublishOptions? = nil) -> Promise<LocalTrackPublication>
    {
        return Promise<LocalTrackPublication> { fulfill, reject in
            if self.localVideoTrackPublications.first(where: { $0.track === track }) != nil {
                reject(TrackError.publishError("This track has already been published."))
                return
            }

            let publishOptions: LocalVideoTrackPublishOptions
            if options == nil {
                publishOptions = LocalVideoTrackPublishOptions()
            } else {
                publishOptions = options!
            }

            do {
                let cid = track.mediaTrack.trackId
                try self.engine?.addTrack(cid: cid, name: track.name, kind: .video, dimensions: track.dimensions)
                    .then { trackInfo in
                        let transInit = RTCRtpTransceiverInit()
                        transInit.direction = .sendOnly
                        transInit.streamIds = [self.streamId]
                        let encodings = track.getVideoEncodings(publishOptions.encoding, simulcast: publishOptions.simulcast)
                        transInit.sendEncodings = encodings

                        track.transceiver = self.engine?.publisher?.peerConnection.addTransceiver(with: track.mediaTrack, init: transInit)
                        if track.transceiver == nil {
                            reject(TrackError.publishError("Nil sender returned from peer connection."))
                            return
                        }

                        let publication = LocalTrackPublication(info: trackInfo, track: track, participant: self)
                        self.addTrack(publication: publication)
                        fulfill(publication)
                    }
            } catch {
                reject(error)
            }
        }
    }

    /// unpublish an existing published track
    /// this will also stop the track
    public func unpublishTrack(track: Track) throws {
        guard let sid = track.sid else {
            throw TrackError.invalidTrackState("This track was never published.")
        }

        switch track.kind {
        case .audio:
            audioTracks.removeValue(forKey: sid)
        case .video:
            videoTracks.removeValue(forKey: sid)
        default:
            return
        }
        let publication = tracks.removeValue(forKey: sid)
        guard publication != nil else {
            throw TrackError.unpublishError("could not find published track for \(sid)")
        }
        track.stop()

        guard let pc = engine?.publisher?.peerConnection else {
            return
        }

        for sender in pc.senders {
            if let t = sender.track {
                if t.isEqual(track.mediaTrack) {
                    pc.removeTrack(sender)
                }
            }
        }
    }

    /**
    publish data to the other participants in the room
    
    Data is forwarded to each participant in the room. Each payload must not exceed 15k.
    - Parameter data: Data to send
    - Parameter reliability: Toggle between sending relialble vs lossy delivery.
      For data that you need delivery guarantee (such as chat messages), use Reliable.
      For data that should arrive as quickly as possible, but you are ok with dropped packets, use Lossy.
    - Parameter destination: SIDs of the participants who will receive the message. If empty, deliver to everyone
    */
    public func publishData(data: Data, reliability: DataPublishReliability, destination: [String] = []) throws {
        if data.count > maxDataPacketSize {
            throw TrackError.publishError("could not publish data more than \(maxDataPacketSize)")
        }

        let kind = Livekit_DataPacket.Kind(rawValue: reliability.rawValue)
        var channel: RTCDataChannel? = engine?.reliableDC
        if kind == .lossy {
            channel = engine?.lossyDC
        }

        if channel == nil || channel?.readyState != .open {
            throw TrackError.publishError("cannot publish data as data channel is not open")
        }

        var dataPacket = Livekit_DataPacket()
        var userPacket = Livekit_UserPacket()
        userPacket.destinationSids = destination
        userPacket.payload = data
        userPacket.participantSid = sid
        dataPacket.user = userPacket

        let buffer = try RTCDataBuffer(data: dataPacket.serializedData(), isBinary: true)
        channel?.sendData(buffer)
    }

    override func updateFromInfo(info: Livekit_ParticipantInfo) {
        super.updateFromInfo(info: info)

        // detect tracks that have been muted remotely, and apply those changes
        for trackInfo in info.tracks {
            guard let publication = getTrackPublication(sid: trackInfo.sid) else {
                // this is unexpected
                continue
            }
            if trackInfo.muted != publication.muted {
                publication.setMuted(trackInfo.muted)
            }
        }
    }

    func setEncodingParameters(parameters _: EncodingParameters) {}

    // if audio session has not been initialized for recording, do so now
    private func ensureAudioCategory() throws {
        let audioSession = AVAudioSession.sharedInstance()
        let desiredCategory = AVAudioSession.Category.playAndRecord
        if !LiveKit.audioConfigured || audioSession.category != desiredCategory {
            logger.warning("upgrading audio session to playAndRecord")
            var opts = audioSession.categoryOptions
            opts.insert(.defaultToSpeaker)
            LiveKit.configureAudioSession(category: desiredCategory, mode: .videoChat)
        }
    }
}
