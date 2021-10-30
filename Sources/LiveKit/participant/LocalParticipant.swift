import WebRTC
import Promises

public class LocalParticipant: Participant {

    private var streamId = "stream"

    public var localAudioTrackPublications: [TrackPublication] { Array(audioTracks.values) }
    public var localVideoTrackPublications: [TrackPublication] { Array(videoTracks.values) }
    weak var engine: Engine?

    convenience init(fromInfo info: Livekit_ParticipantInfo, engine: Engine, room: Room) {
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
                                  options: LocalAudioTrackPublishOptions? = nil) -> Promise<LocalTrackPublication> {

        guard let engine = engine else {
            return Promise(EngineError.invalidState("engine is null"))
        }

        let options = options ?? engine.connectOptions.defaultAudioPublishOptions

        if localAudioTrackPublications.first(where: { $0.track === track }) != nil {
            return Promise(TrackError.publishError("This track has already been published."))
        }

        let cid = track.mediaTrack.trackId
        return engine.addTrack(cid: cid, name: track.name, kind: .audio).then { trackInfo in

            Promise<LocalTrackPublication> { () -> LocalTrackPublication in

                track.start()

                let transInit = RTCRtpTransceiverInit()
                transInit.direction = .sendOnly
                transInit.streamIds = [self.streamId]

                let transceiver = self.engine?.publisher?.pc.addTransceiver(with: track.mediaTrack, init: transInit)
                if transceiver == nil {
                    throw TrackError.publishError("Nil sender returned from peer connection.")
                }

                engine.publisherShouldNegotiate()

                let publication = LocalTrackPublication(info: trackInfo, track: track, participant: self)
                self.addTrack(publication: publication)

                // notify didPublish
                self.notify { $0.localParticipant(self, didPublish: publication) }
                self.room?.notify { $0.room(self.room!, localParticipant: self, didPublish: publication) }

                return publication
            }
        }
    }

    /// publish a new video track to the Room
    public func publishVideoTrack(track: LocalVideoTrack,
                                  options: LocalVideoTrackPublishOptions? = nil) -> Promise<LocalTrackPublication> {

        logger.debug("[Publish] video")

        guard let engine = engine else {
            return Promise(EngineError.invalidState("engine is null"))
        }

        let options = options ?? engine.connectOptions.defaultVideoPublishOptions

        if localVideoTrackPublications.first(where: { $0.track === track }) != nil {
            return Promise(TrackError.publishError("This track has already been published."))
        }

        let cid = track.mediaTrack.trackId
        return engine.addTrack(cid: cid,
                               name: track.name,
                               kind: .video,
                               dimensions: track.dimensions) .then { trackInfo in

                                Promise<LocalTrackPublication> { () -> LocalTrackPublication in

                                    track.start()

                                    let transInit = RTCRtpTransceiverInit()
                                    transInit.direction = .sendOnly
                                    transInit.streamIds = [self.streamId]

                                    if let encodings = Utils.computeEncodings(dimensions: track.dimensions, publishOptions: options) {
                                        print("using encodings %@", encodings)
                                        transInit.sendEncodings = encodings
                                    }

                                    track.transceiver = self.engine?.publisher?.pc.addTransceiver(with: track.mediaTrack, init: transInit)
                                    if track.transceiver == nil {
                                        throw TrackError.publishError("Nil sender returned from peer connection.")
                                    }

                                    engine.publisherShouldNegotiate()

                                    let publication = LocalTrackPublication(info: trackInfo, track: track, participant: self)
                                    self.addTrack(publication: publication)

                                    // notify didPublish
                                    self.notify { $0.localParticipant(self, didPublish: publication) }
                                    self.room?.notify { $0.room(self.room!, localParticipant: self, didPublish: publication) }

                                    return publication
                                }
                               }
    }

    public func unpublishAll(shouldNotify: Bool = true) -> Promise<[Void]> {
        // build a list of promises
        let promises = tracks.values.compactMap { $0 as? LocalTrackPublication }
            .map { unpublish(publication: $0, shouldNotify: shouldNotify) }
        // combine promises to wait all to complete
        return all(promises)
    }

    /// unpublish an existing published track
    /// this will also stop the track
    public func unpublish(publication: LocalTrackPublication, shouldNotify: Bool = true) -> Promise<Void> {

        func notifyDidUnpublish() -> Promise<Void> {
            Promise<Void> {
                guard shouldNotify else { return }
                // notify unpublish
                self.notify { $0.localParticipant(self, didUnpublish: publication) }
                self.room?.notify { $0.room(self.room!, localParticipant: self, didUnpublish: publication) }
            }
        }

        // remove the publication
        tracks.removeValue(forKey: publication.sid)

        // if track is nil, only notify unpublish and return
        guard let track = publication.track else {
            return notifyDidUnpublish()
        }

        // wait for track to stop
        return track.stop().then { () -> Void in

            if let pc = self.engine?.publisher?.pc,
               let sender = track.sender {
                pc.removeTrack(sender)
                self.engine?.publisherShouldNegotiate()
            }

        }.then {
            notifyDidUnpublish()
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

    //    func setEncodingParameters(parameters _: EncodingParameters) {}
}
