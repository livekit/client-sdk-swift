import WebRTC
import Promises

public class LocalParticipant: Participant {

    public var localAudioTrackPublications: [TrackPublication] { Array(audioTracks.values) }
    public var localVideoTrackPublications: [TrackPublication] { Array(videoTracks.values) }

    convenience init(from info: Livekit_ParticipantInfo,
                     room: Room) {

        self.init(sid: info.sid,
                  identity: info.identity,
                  name: info.name,
                  room: room)

        updateFromInfo(info: info)
    }

    public func getTrackPublication(sid: String) -> LocalTrackPublication? {
        return tracks[sid] as? LocalTrackPublication
    }

    /// publish a new audio track to the Room
    public func publishAudioTrack(track: LocalAudioTrack,
                                  publishOptions: AudioPublishOptions? = nil) -> Promise<LocalTrackPublication> {

        guard let publisher = room.engine.publisher else {
            return Promise(EngineError.invalidState("publisher is null"))
        }

        let publishOptions = publishOptions ?? room.roomOptions?.defaultAudioPublishOptions

        if localAudioTrackPublications.first(where: { $0.track === track }) != nil {
            return Promise(TrackError.publishError("This track has already been published."))
        }

        let cid = track.mediaTrack.trackId

        let transInit = RTCRtpTransceiverInit()
        transInit.direction = .sendOnly

        return track.start()
            .recover { (error) -> Void in
                logger.warning("Failed to start track with error \(error)")
                // start() will fail if it's already started.
                // but for this case we will allow it, throw for any other error.
                guard case TrackError.invalidTrackState = error else { throw error }
            }.then {
                // request a new track to the server
                self.room.engine.addTrack(cid: cid,
                                          name: track.name,
                                          kind: .audio,
                                          source: track.source.toPBType()) {
                    $0.disableDtx = !(publishOptions?.dtx ?? true)
                }
            }.then { (trackInfo) -> Promise<(RTCRtpTransceiver, Livekit_TrackInfo)> in
                // add transceiver to pc
                publisher.addTransceiver(with: track.mediaTrack,
                                         transceiverInit: transInit).then { transceiver in
                                            // pass down trackInfo and created transceiver
                                            (transceiver, trackInfo)
                                         }
            }.then { (transceiver, trackInfo) -> LocalTrackPublication in

                // store publishOptions used for this track
                // track.publishOptions = publishOptions TODO: FIX
                track.transceiver = transceiver

                self.room.engine.publisherShouldNegotiate()

                let publication = LocalTrackPublication(info: trackInfo, track: track, participant: self)
                self.addTrack(publication: publication)

                // notify didPublish
                self.notify { $0.localParticipant(self, didPublish: publication) }
                self.room.notify { $0.room(self.room, localParticipant: self, didPublish: publication) }

                return publication
            }
    }

    /// publish a new video track to the Room
    public func publishVideoTrack(track: LocalVideoTrack,
                                  publishOptions: VideoPublishOptions? = nil) -> Promise<LocalTrackPublication> {

        guard let publisher = room.engine.publisher else {
            return Promise(EngineError.invalidState("publisher is null"))
        }

        let publishOptions = publishOptions ?? room.roomOptions?.defaultVideoPublishOptions

        if localVideoTrackPublications.first(where: { $0.track === track }) != nil {
            return Promise(TrackError.publishError("This track has already been published."))
        }

        let cid = track.mediaTrack.trackId

        let transInit = DispatchQueue.webRTC.sync { RTCRtpTransceiverInit() }
        transInit.direction = .sendOnly

        #if LK_COMPUTE_VIDEO_SENDER_PARAMETERS

        let encodings = Utils.computeEncodings(dimensions: track.capturer.dimensions,
                                               publishOptions: publishOptions)

        if let encodings = encodings {
            logger.debug("using encodings \(encodings)")
            transInit.sendEncodings = encodings
        }

        let layers = Utils.videoLayersForEncodings(dimensions: track.capturer.dimensions,
                                                   encodings: encodings)
        #else
        transInit.sendEncodings = [
            RTCRtpEncodingParameters(rid: "f"),
            RTCRtpEncodingParameters(rid: "h"),
            RTCRtpEncodingParameters(rid: "q")
        ]
        #endif

        // try to start the track
        return track.start()
            .recover { (error) -> Void in
                logger.warning("Failed to start track with error \(error)")
                // start() will fail if it's already started.
                // but for this case we will allow it, throw for any other error.
                guard case TrackError.invalidTrackState = error else { throw error }
            }.then { () -> Promise<Livekit_TrackInfo> in
                // request a new track to the server
                self.room.engine.addTrack(cid: cid,
                                          name: track.name,
                                          kind: .video,
                                          source: track.source.toPBType()) {
                    // depending on the capturer, dimensions may not be available at this point
                    if let dimensions = track.capturer.dimensions {
                        $0.width = UInt32(dimensions.width)
                        $0.height = UInt32(dimensions.height)
                    }
                    #if LK_COMPUTE_VIDEO_SENDER_PARAMETERS
                    $0.layers = layers
                    #else
                    // set a single layer if compute sender parameters is off
                    $0.layers = [
                        Livekit_VideoLayer.with({
                            if let dimensions = track.capturer.dimensions {
                                $0.width = UInt32(dimensions.width)
                                $0.height = UInt32(dimensions.height)
                            }
                            $0.quality = Livekit_VideoQuality.high
                            $0.bitrate = 0
                        })
                    ]
                    #endif
                }
            }.then { (trackInfo) -> Promise<(RTCRtpTransceiver, Livekit_TrackInfo)> in
                // add transceiver to pc
                publisher.addTransceiver(with: track.mediaTrack,
                                         transceiverInit: transInit).then { transceiver in
                                            // pass down trackInfo and created transceiver
                                            (transceiver, trackInfo)
                                         }
            }.then { (transceiver, trackInfo) -> LocalTrackPublication in

                // store publishOptions used for this track
                track.publishOptions = publishOptions
                track.transceiver = transceiver

                self.room.engine.publisherShouldNegotiate()

                let publication = LocalTrackPublication(info: trackInfo, track: track, participant: self)
                self.addTrack(publication: publication)

                // notify didPublish
                self.notify { $0.localParticipant(self, didPublish: publication) }
                self.room.notify { $0.room(self.room, localParticipant: self, didPublish: publication) }

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
                self.room.notify { $0.room(self.room, localParticipant: self, didUnpublish: publication) }
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
            let options = room.roomOptions ?? RoomOptions()
            if options.stopLocalTrackOnUnpublish {
                return track.stop()
            }
            // Do nothing
            return Promise(())
        }

        // wait for track to stop
        return stopTrackIfRequired()
            .recover { error in logger.warning("stopTrackIfRequired() did throw \(error)") }
            .then { () -> Promise<Void> in

                guard let publisher = self.room.engine.publisher, let sender = track.sender else {
                    return Promise(())
                }

                return publisher.removeTrack(sender).then {
                    self.room.engine.publisherShouldNegotiate()
                }
            }.then { () -> Promise<Void> in
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
                            reliability: Reliability = .reliable,
                            destination: [String] = []) -> Promise<Void> {

        let userPacket = Livekit_UserPacket.with {
            $0.destinationSids = destination
            $0.payload = data
            $0.participantSid = self.sid
        }

        return room.engine.send(userPacket: userPacket,
                                reliability: reliability)
    }
    

    /**
     * Control who can subscribe to LocalParticipant's published tracks.
     *
     * By default, all participants can subscribe. This allows fine-grained control over
     * who is able to subscribe at a participant and track level.
     *
     * Note: if access is given at a track-level (i.e. both ``allParticipantsAllowed`` and
     * ``ParticipantTrackPermission/allTracksAllowed`` are false), any newer published tracks
     * will not grant permissions to any participants and will require a subsequent
     * permissions update to allow subscription.
     *
     * - Parameter allParticipantsAllowed Allows all participants to subscribe all tracks.
     *  Takes precedence over ``participantTrackPermissions`` if set to true.
     *  By default this is set to true.
     * - Parameter participantTrackPermissions Full list of individual permissions per
     *  participant/track. Any omitted participants will not receive any permissions.
     */
    public func setTrackSubscriptionPermissions(allParticipantsAllowed: Bool,
                                               trackPermissions: [ParticipantTrackPermission] = []){
        room.engine.signalClient.sendUpdateSubscriptionPermissions(allParticipants: allParticipantsAllowed, participantTrackPermissions: trackPermissions)
    }

    internal func onSubscribedQualitiesUpdate(trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) {

        if !(room.roomOptions?.dynacast ?? false) {
            return
        }
        guard let pub = getTrackPublication(sid: trackSid),
              let track = pub.track as? LocalVideoTrack,
              let sender = track.transceiver?.sender
        else {
            return
        }

        let parameters = sender.parameters
        let encodings = parameters.encodings

        var hasChanged = false
        for quality in subscribedQualities {

            var rid: String
            switch quality.quality {
            case Livekit_VideoQuality.high: rid = "f"
            case Livekit_VideoQuality.medium: rid = "h"
            case Livekit_VideoQuality.low: rid = "q"
            default: continue
            }

            guard let encoding = encodings.first(where: { $0.rid == rid }) else {
                continue
            }

            if encoding.isActive != quality.enabled {
                hasChanged = true
                encoding.isActive = quality.enabled
                logger.info("setting layer \(quality.quality) to \(quality.enabled)")
            }
        }

        // Non simulcast streams don't have rids, handle here.
        if encodings.count == 1 && subscribedQualities.count >= 1 {
            let encoding = encodings[0]
            let quality = subscribedQualities[0]

            if encoding.isActive != quality.enabled {
                hasChanged = true
                encoding.isActive = quality.enabled
                logger.info("setting layer \(quality.quality) to \(quality.enabled)")
            }
        }

        if hasChanged {
            sender.parameters = parameters
        }
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
                let localTrack = LocalVideoTrack.createCameraTrack(options: room.roomOptions?.defaultVideoCaptureOptions)
                return publishVideoTrack(track: localTrack).then { publication in return publication }
            } else if source == .microphone {
                let localTrack = LocalAudioTrack.createTrack(name: "", options: room.roomOptions?.defaultAudioCaptureOptions)
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
