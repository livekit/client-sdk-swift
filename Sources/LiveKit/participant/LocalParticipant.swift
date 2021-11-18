import WebRTC
import Promises

public class LocalParticipant: Participant {

    private var streamId = "stream"

    public var localAudioTrackPublications: [TrackPublication] { Array(audioTracks.values) }
    public var localVideoTrackPublications: [TrackPublication] { Array(videoTracks.values) }

    convenience init(fromInfo info: Livekit_ParticipantInfo, room: Room) {
        self.init(sid: info.sid)
        self.room = room
        updateFromInfo(info: info)
    }

    public func getTrackPublication(sid: String) -> LocalTrackPublication? {
        return tracks[sid] as? LocalTrackPublication
    }

    /// publish a new audio track to the Room
    public func publishAudioTrack(track: LocalAudioTrack,
                                  publishOptions: LocalAudioTrackPublishOptions? = nil) -> Promise<LocalTrackPublication> {

        guard let engine = room?.engine else {
            return Promise(EngineError.invalidState("engine is null"))
        }

        let publishOptions = publishOptions ?? engine.options?.defaultAudioPublishOptions

        if localAudioTrackPublications.first(where: { $0.track === track }) != nil {
            return Promise(TrackError.publishError("This track has already been published."))
        }

        let cid = track.mediaTrack.trackId

        return track.start()
            .recover { (error) -> Void in
                logger.warning("Failed to start track with error \(error)")
                // start() will fail if it's already started.
                // but for this case we will allow it, throw for any other error.
                guard case TrackError.invalidTrackState = error else { throw error }
            }.then {
                engine.addTrack(cid: cid, name: track.name, kind: .audio) {
                    $0.disableDtx = !(publishOptions?.dtx ?? true)
                }
            }.then { (trackInfo) -> LocalTrackPublication in

                let transInit = RTCRtpTransceiverInit()
                transInit.direction = .sendOnly
                transInit.streamIds = [self.streamId]

                let transceiver = self.room?.engine.publisher?.pc.addTransceiver(with: track.mediaTrack, init: transInit)
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

    /// publish a new video track to the Room
    public func publishVideoTrack(track: LocalVideoTrack,
                                  publishOptions: LocalVideoTrackPublishOptions? = nil) -> Promise<LocalTrackPublication> {

        guard let engine = room?.engine else {
            return Promise(EngineError.invalidState("engine is null"))
        }

        let publishOptions = publishOptions ?? engine.options?.defaultVideoPublishOptions

        if localVideoTrackPublications.first(where: { $0.track === track }) != nil {
            return Promise(TrackError.publishError("This track has already been published."))
        }

        let cid = track.mediaTrack.trackId

        // try to start the track
        return track.start()
            .recover { (error) -> Void in
                logger.warning("Failed to start track with error \(error)")
                // start() will fail if it's already started.
                // but for this case we will allow it, throw for any other error.
                guard case TrackError.invalidTrackState = error else { throw error }
            }.then {
                // request a new track to the server
                engine.addTrack(cid: cid,
                                name: track.name,
                                kind: .video) {
                    // depending on the capturer, dimensions may not be available at this point
                    if let dimensions = track.capturer.dimensions {
                        $0.width = UInt32(dimensions.width)
                        $0.height = UInt32(dimensions.height)
                    }
                }
            }.then { (trackInfo) -> LocalTrackPublication in

                let transInit = RTCRtpTransceiverInit()
                transInit.direction = .sendOnly
                transInit.streamIds = [self.streamId]

                if let encodings = Utils.computeEncodings(dimensions: track.capturer.dimensions!,
                                                          publishOptions: publishOptions) {
                    logger.debug("using encodings \(encodings)")
                    transInit.sendEncodings = encodings
                }

                track.transceiver = self.room?.engine.publisher?.pc.addTransceiver(with: track.mediaTrack, init: transInit)
                if track.transceiver == nil {
                    throw TrackError.publishError("Failed to addTransceiver")
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
        return track.stop().always { () -> Void in

            if let pc = self.room?.engine.publisher?.pc,
               let sender = track.sender {
                pc.removeTrack(sender)
                self.room?.engine.publisherShouldNegotiate()
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
        var channel: RTCDataChannel? = room?.engine.reliableDC
        if kind == .lossy {
            channel = room?.engine.lossyDC
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
                publication.muted = trackInfo.muted
            }
        }
    }

    //    func setEncodingParameters(parameters _: EncodingParameters) {}
}

// MARK: - Simplified API

extension LocalParticipant {

    public func setCamera(enabled: Bool, interceptor: VideoCaptureInterceptor? = nil) -> Promise<LocalTrackPublication?> {
        return set(source: .camera, enabled: enabled, interceptor: interceptor)
    }

    public func setMicrophone(enabled: Bool) -> Promise<LocalTrackPublication?> {
        return set(source: .microphone, enabled: enabled)
    }

    public func setScreen(enabled: Bool) -> Promise<LocalTrackPublication?> {
        return set(source: .screenShareVideo, enabled: enabled)
    }

    public func set(source: Track.Source, enabled: Bool, interceptor: VideoCaptureInterceptor? = nil) -> Promise<LocalTrackPublication?> {
        let publication = getTrackPublication(source: source)
        if let publication = publication as? LocalTrackPublication,
           let track = publication.track {
            // publication already exists
            if enabled {
                publication.muted = false
                track.start()
                return Promise(publication)
            } else {
                publication.muted = true
                track.stop()
                return Promise(nil)
            }
        } else if enabled {
            // try to create a new track
            if source == .camera {
                let localTrack = LocalVideoTrack.createCameraTrack(interceptor: interceptor)
                return publishVideoTrack(track: localTrack).then { publication in return publication }
            } else if source == .microphone {
                let localTrack = LocalAudioTrack.createTrack(name: "")
                return publishAudioTrack(track: localTrack).then { publication in return publication }
            } else if source == .screenShareVideo {

                var localTrack: LocalVideoTrack?

                #if !os(macOS)
                // iOS defaults to in-app screen share only since background screen share
                // requires a broadcast extension (iOS limitation).
                localTrack = LocalVideoTrack.createInAppScreenShareTrack()
                #else
                localTrack = LocalVideoTrack.createDesktopTrack()
                #endif

                if let localTrack = localTrack {
                    return publishVideoTrack(track: localTrack).then { publication in return publication }
                }
            }
        }

        return Promise(EngineError.invalidState())
    }
}
