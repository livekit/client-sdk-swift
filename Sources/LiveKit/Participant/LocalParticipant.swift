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
                                  publishOptions: AudioPublishOptions? = nil) -> Promise<LocalTrackPublication> {

        guard let engine = room?.engine else {
            return Promise(EngineError.invalidState("engine is null"))
        }

        let publishOptions = publishOptions ?? room?.roomOptions?.defaultAudioPublishOptions

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
                // request a new track to the server
                engine.addTrack(cid: cid,
                                name: track.name,
                                kind: .audio,
                                source: track.source.toPBType()) {
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
                                  publishOptions: VideoPublishOptions? = nil) -> Promise<LocalTrackPublication> {

        guard let engine = room?.engine else {
            return Promise(EngineError.invalidState("engine is null"))
        }

        let publishOptions = publishOptions ?? room?.roomOptions?.defaultVideoPublishOptions

        if localVideoTrackPublications.first(where: { $0.track === track }) != nil {
            return Promise(TrackError.publishError("This track has already been published."))
        }

        let cid = track.mediaTrack.trackId

        let transInit = RTCRtpTransceiverInit()
        transInit.direction = .sendOnly
        transInit.streamIds = [self.streamId]

        let encodings = Utils.computeEncodings(dimensions: track.capturer.dimensions,
                                               publishOptions: publishOptions)

        if let encodings = encodings {
            logger.debug("using encodings \(encodings)")
            transInit.sendEncodings = encodings
        }

        let layers = Utils.videoLayersForEncodings(dimensions: track.capturer.dimensions,
                                                   encodings: encodings)

        // try to start the track
        return track.start()
            .recover { (error) -> Void in
                logger.warning("Failed to start track with error \(error)")
                // start() will fail if it's already started.
                // but for this case we will allow it, throw for any other error.
                guard case TrackError.invalidTrackState = error else { throw error }
            }.then { () -> Promise<(Livekit_TrackInfo)> in

                // request a new track to the server
                engine.addTrack(cid: cid,
                                name: track.name,
                                kind: .video,
                                source: track.source.toPBType()) {
                    // depending on the capturer, dimensions may not be available at this point
                    if let dimensions = track.capturer.dimensions {
                        $0.width = UInt32(dimensions.width)
                        $0.height = UInt32(dimensions.height)
                    }
                    $0.layers = layers
                }
            }.then { (trackInfo) -> LocalTrackPublication in

                // store publishOptions used for this track
                track.publishOptions = publishOptions

                track.transceiver = self.room?.engine.publisher?.pc.addTransceiver(with: track.mediaTrack,
                                                                                   init: transInit)
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

        // build a conditional promise to stop track if required by option
        func stopTrackIfRequired() -> Promise<Void> {
            let options = room?.roomOptions ?? RoomOptions()
            if options.stopLocalTrackOnUnpublish {
                return track.stop()
            }
            // Do nothing
            return Promise(())
        }

        // wait for track to stop
        return stopTrackIfRequired().always { () -> Void in

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
    @discardableResult
    public func publishData(data: Data,
                            reliability: DataPublishReliability = .reliable,
                            destination: [String] = []) -> Promise<Void> {

        guard let engine = room?.engine else {
            return Promise(EngineError.invalidState("Room is nil"))
        }

        let userPacket = Livekit_UserPacket.with {
            $0.destinationSids = destination
            $0.payload = data
            $0.participantSid = self.sid
        }

        return engine.send(userPacket: userPacket,
                           reliability: reliability)
    }
}

// MARK: - Simplified API

extension LocalParticipant {

    public func setCamera(enabled: Bool) -> Promise<LocalTrackPublication?> {
        return set(source: .camera, enabled: enabled)
    }

    public func setMicrophone(enabled: Bool) -> Promise<LocalTrackPublication?> {
        return set(source: .microphone, enabled: enabled)
    }

    /// Enable or disable screen sharing. This has different behavior depending on the platform.
    ///
    /// For iOS, this will use ``InAppScreenCapturer`` to capture in-app screen only due to Apple's limitation.
    /// If you would like to capture the screen when the app is in the background, you will need to create a "Broadcast Upload Extension".
    ///
    /// For macOS, this will use ``MacOSScreenCapturer`` to capture the main screen. ``MacOSScreenCapturer`` has the ability
    /// to capture other screens and windows. See ``MacOSScreenCapturer`` for details.
    ///
    /// For advanced usage, you can create a relevant ``LocalVideoTrack`` and call ``LocalParticipant/publishVideoTrack(track:publishOptions:)``.
    public func setScreenShare(enabled: Bool) -> Promise<LocalTrackPublication?> {
        return set(source: .screenShareVideo, enabled: enabled)
    }

    public func set(source: Track.Source, enabled: Bool) -> Promise<LocalTrackPublication?> {
        let publication = getTrackPublication(source: source)
        if let publication = publication as? LocalTrackPublication {
            // publication already exists
            if enabled {
                return publication.unmute().then { publication }
            } else {
                return publication.mute().then { nil }
            }
        } else if enabled {
            // try to create a new track
            if source == .camera {
                let localTrack = LocalVideoTrack.createCameraTrack(options: room?.roomOptions?.defaultVideoCaptureOptions)
                return publishVideoTrack(track: localTrack).then { publication in return publication }
            } else if source == .microphone {
                let localTrack = LocalAudioTrack.createTrack(name: "", options: room?.roomOptions?.defaultAudioCaptureOptions)
                return publishAudioTrack(track: localTrack).then { publication in return publication }
            } else if source == .screenShareVideo {

                var localTrack: LocalVideoTrack?

                #if os(iOS)
                // iOS defaults to in-app screen share only since background screen share
                // requires a broadcast extension (iOS limitation).
                localTrack = LocalVideoTrack.createInAppScreenShareTrack()
                #elseif os(macOS)
                localTrack = LocalVideoTrack.createMacOSScreenShareTrack()
                #endif

                if let localTrack = localTrack {
                    return publishVideoTrack(track: localTrack).then { publication in return publication }
                }
            }
        }

        return Promise(EngineError.invalidState())
    }
}
