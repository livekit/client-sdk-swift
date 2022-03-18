import WebRTC
import Promises

public class LocalParticipant: Participant {

    public var localAudioTracks: [LocalTrackPublication] { audioTracks.compactMap { $0 as? LocalTrackPublication } }
    public var localVideoTracks: [LocalTrackPublication] { videoTracks.compactMap { $0 as? LocalTrackPublication } }

    convenience init(from info: Livekit_ParticipantInfo,
                     room: Room) {

        self.init(sid: info.sid,
                  identity: info.identity,
                  name: info.name,
                  room: room)

        updateFromInfo(info: info)
    }

    internal override func cleanUp() -> Promise<Void> {
        super.cleanUp().then {
            self.unpublishAll(shouldNotify: false)
        }
    }

    public func getTrackPublication(sid: Sid) -> LocalTrackPublication? {
        return tracks[sid] as? LocalTrackPublication
    }

    internal func publish(track: LocalTrack,
                          publishOptions: PublishOptions? = nil) -> Promise<LocalTrackPublication> {

        guard let publisher = room.engine.publisher else {
            return Promise(EngineError.state(message: "publisher is null"))
        }

        guard tracks.values.first(where: { $0.track === track }) == nil else {
            return Promise(TrackError.publish(message: "This track has already been published."))
        }

        guard track is LocalVideoTrack || track is LocalAudioTrack else {
            return Promise(TrackError.publish(message: "Unknown LocalTrack type"))
        }

        let transInit = DispatchQueue.webRTC.sync { RTCRtpTransceiverInit() }
        transInit.direction = .sendOnly

        // try to start the track
        return track.start()
            .recover { (error) -> Void in
                self.log("Failed to start track with error \(error)", .warning)
                // start() will fail if it's already started.
                // but for this case we will allow it, throw for any other error.
                guard case TrackError.state = error else { throw error }
            }.then(on: .sdk) { () -> Promise<Livekit_TrackInfo> in

                var videoLayers: [Livekit_VideoLayer] = []

                if let track = track as? LocalVideoTrack {
                    // track.start() should only complete when it generates at least 1 frame which then can determine dimensions
                    // assert(track.capturer.dimensions != nil, "VideoCapturer's dimensions should be determined at this point")

                    guard let dimensions = track.capturer.dimensions else {
                        throw TrackError.publish(message: "VideoCapturer dimensions are unknown")
                    }

                    let publishOptions = (publishOptions as? VideoPublishOptions) ?? self.room.options.defaultVideoPublishOptions

                    self.log("Capturer dimensions: \(String(describing: track.capturer.dimensions))")

                    let encodings = Utils.computeEncodings(dimensions: dimensions,
                                                           publishOptions: publishOptions,
                                                           isScreenShare: track.source == .screenShareVideo)

                    self.log("Using encodings \(encodings)")
                    transInit.sendEncodings = encodings

                    videoLayers = dimensions.videoLayers(for: encodings)

                    self.log("Using encodings layers: \(videoLayers.map { String(describing: $0) }.joined(separator: ", "))")
                }
                // request a new track to the server
                return self.room.engine.addTrack(cid: track.mediaTrack.trackId,
                                                 name: track.name,
                                                 kind: track.kind.toPBType(),
                                                 source: track.source.toPBType()) {

                    if let track = track as? LocalVideoTrack {
                        // additional params for Video

                        if let dimensions = track.capturer.dimensions {
                            $0.width = UInt32(dimensions.width)
                            $0.height = UInt32(dimensions.height)
                        }

                        $0.layers = videoLayers

                    } else if track is LocalAudioTrack {
                        // additional params for Audio
                        let publishOptions = (publishOptions as? AudioPublishOptions) ?? self.room.options.defaultAudioPublishOptions
                        $0.disableDtx = !publishOptions.dtx
                    }
                }
            }.then(on: .sdk) { (trackInfo) -> Promise<(RTCRtpTransceiver, Livekit_TrackInfo)> in
                // add transceiver to pc
                publisher.addTransceiver(with: track.mediaTrack,
                                         transceiverInit: transInit).then(on: .sdk) { transceiver in
                                            // pass down trackInfo and created transceiver
                                            (transceiver, trackInfo)
                                         }
            }.then(on: .sdk) { params in
                track.publish().then { params }
            }.then(on: .sdk) { (transceiver, trackInfo) -> LocalTrackPublication in

                // store publishOptions used for this track
                track.publishOptions = publishOptions
                track.transceiver = transceiver

                if track.source == .screenShareVideo {
                    // prefer to maintain resolution for screen share
                    let params = transceiver.sender.parameters
                    params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
                    // changing params directly doesn't work so we need to update params
                    // and set it back to sender.parameters
                    transceiver.sender.parameters = params
                }

                self.room.engine.publisherShouldNegotiate()

                let publication = LocalTrackPublication(info: trackInfo, track: track, participant: self)
                self.addTrack(publication: publication)

                // notify didPublish
                self.notify { $0.localParticipant(self, didPublish: publication) }
                self.room.notify { $0.room(self.room, localParticipant: self, didPublish: publication) }

                return publication
            }
    }

    /// publish a new audio track to the Room
    public func publishAudioTrack(track: LocalAudioTrack,
                                  publishOptions: AudioPublishOptions? = nil) -> Promise<LocalTrackPublication> {

        publish(track: track, publishOptions: publishOptions)
    }

    /// publish a new video track to the Room
    public func publishVideoTrack(track: LocalVideoTrack,
                                  publishOptions: VideoPublishOptions? = nil) -> Promise<LocalTrackPublication> {

        publish(track: track, publishOptions: publishOptions)
    }

    public func unpublishAll(shouldNotify: Bool = true) -> Promise<Void> {
        // build a list of promises
        let promises = tracks.values.compactMap { $0 as? LocalTrackPublication }
            .map { unpublish(publication: $0, shouldNotify: shouldNotify) }
        // combine promises to wait all to complete
        return promises.all(on: .sdk)
    }

    /// unpublish an existing published track
    /// this will also stop the track
    public func unpublish(publication: LocalTrackPublication, shouldNotify: Bool = true) -> Promise<Void> {

        func notifyDidUnpublish() -> Promise<Void> {
            Promise<Void>(on: .sdk) {
                guard shouldNotify else { return }
                // notify unpublish
                self.notify { $0.localParticipant(self, didUnpublish: publication) }
                self.room.notify { $0.room(self.room, localParticipant: self, didUnpublish: publication) }
            }
        }

        // remove the publication
        tracks.removeValue(forKey: publication.sid)

        // if track is nil, only notify unpublish and return
        guard let track = publication.track as? LocalTrack else {
            return notifyDidUnpublish()
        }

        // build a conditional promise to stop track if required by option
        func stopTrackIfRequired() -> Promise<Void> {
            if room.options.stopLocalTrackOnUnpublish {
                return track.stop()
            }
            // Do nothing
            return Promise(())
        }

        // wait for track to stop
        return stopTrackIfRequired()
            .recover { error in self.log("stopTrackIfRequired() did throw \(error)", .warning) }
            .then(on: .sdk) { () -> Promise<Void> in

                guard let publisher = self.room.engine.publisher, let sender = track.sender else {
                    return Promise(())
                }

                return publisher.removeTrack(sender).then(on: .sdk) {
                    self.room.engine.publisherShouldNegotiate()
                }
            }.then(on: .sdk) {
                track.unpublish()
            }.then(on: .sdk) { () -> Promise<Void> in
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
    @discardableResult
    public func setTrackSubscriptionPermissions(allParticipantsAllowed: Bool,
                                                trackPermissions: [ParticipantTrackPermission] = []) -> Promise<Void> {

        return room.engine.signalClient.sendUpdateSubscriptionPermission(allParticipants: allParticipantsAllowed,
                                                                         trackPermissions: trackPermissions)
    }

    internal func onSubscribedQualitiesUpdate(trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) {

        if !room.options.dynacast {
            return
        }

        guard let pub = getTrackPublication(sid: trackSid),
              let track = pub.track as? LocalVideoTrack,
              let sender = track.transceiver?.sender
        else { return }

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
                log("setting layer \(quality.quality) to \(quality.enabled)", .info)
            }
        }

        // Non simulcast streams don't have rids, handle here.
        if encodings.count == 1 && subscribedQualities.count >= 1 {
            let encoding = encodings[0]
            let quality = subscribedQualities[0]

            if encoding.isActive != quality.enabled {
                hasChanged = true
                encoding.isActive = quality.enabled
                log("setting layer \(quality.quality) to \(quality.enabled)", .info)
            }
        }

        if hasChanged {
            sender.parameters = parameters
        }
    }
}

// MARK: - Session Migration

extension LocalParticipant {

    internal func publishedTracksInfo() -> [Livekit_TrackPublishedResponse] {
        tracks.values.filter { $0.track != nil }
            .map { publication in
                Livekit_TrackPublishedResponse.with {
                    $0.cid = publication.track!.mediaTrack.trackId
                    if let info = publication.latestInfo {
                        $0.track = info
                    }
                }
            }
    }

    internal func republishTracks() -> Promise<Void> {

        let mediaTracks = tracks.values.map { $0.track }.compactMap { $0 }

        return unpublishAll().then(on: .sdk) { () -> Promise<Void> in

            let promises = mediaTracks.map { track -> Promise<LocalTrackPublication>? in
                guard let track = track as? LocalTrack else { return nil }
                return self.publish(track: track, publishOptions: track.publishOptions)
            }.compactMap { $0 }

            return all(on: .sdk, promises).then(on: .sdk) { _ in }
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
                return publication.unmute().then(on: .sdk) { publication }
            } else {
                return publication.mute().then(on: .sdk) { nil }
            }
        } else if enabled {
            // try to create a new track
            if source == .camera {
                let localTrack = LocalVideoTrack.createCameraTrack(options: room.options.defaultCameraCaptureOptions)
                return publishVideoTrack(track: localTrack).then(on: .sdk) { return $0 }
            } else if source == .microphone {
                let localTrack = LocalAudioTrack.createTrack(name: "", options: room.options.defaultAudioCaptureOptions)
                return publishAudioTrack(track: localTrack).then(on: .sdk) { return $0 }
            } else if source == .screenShareVideo {

                var localTrack: LocalVideoTrack?

                #if os(iOS)
                // iOS defaults to in-app screen share only since background screen share
                // requires a broadcast extension (iOS limitation).
                localTrack = LocalVideoTrack.createInAppScreenShareTrack(options: room.options.defaultScreenShareCaptureOptions)
                #elseif os(macOS)
                localTrack = LocalVideoTrack.createMacOSScreenShareTrack(options: room.options.defaultScreenShareCaptureOptions)
                #endif

                if let localTrack = localTrack {
                    return publishVideoTrack(track: localTrack).then(on: .sdk) { publication in return publication }
                }
            }
        }

        return Promise(EngineError.state())
    }
}
