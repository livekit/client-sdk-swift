/*
 * Copyright 2024 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

#if canImport(ReplayKit)
    import ReplayKit
#endif

@_implementationOnly import WebRTC

@objc
public class LocalParticipant: Participant {
    @objc
    public var localAudioTracks: [LocalTrackPublication] { audioTracks.compactMap { $0 as? LocalTrackPublication } }

    @objc
    public var localVideoTracks: [LocalTrackPublication] { videoTracks.compactMap { $0 as? LocalTrackPublication } }

    private var allParticipantsAllowed: Bool = true
    private var trackPermissions: [ParticipantTrackPermission] = []

    init(room: Room) {
        super.init(sid: "", identity: "", room: room)
    }

    func getTrackPublication(sid: Sid) -> LocalTrackPublication? {
        _state.trackPublications[sid] as? LocalTrackPublication
    }

    @objc
    @discardableResult
    func publish(track: LocalTrack, publishOptions: PublishOptions? = nil) async throws -> LocalTrackPublication {
        log("[publish] \(track) options: \(String(describing: publishOptions ?? nil))...", .info)

        guard let publisher = room.engine.publisher else {
            throw LiveKitError(.invalidState, message: "Publisher is nil")
        }

        guard _state.trackPublications.values.first(where: { $0.track === track }) == nil else {
            throw LiveKitError(.invalidState, message: "This track has already been published.")
        }

        guard track is LocalVideoTrack || track is LocalAudioTrack else {
            throw LiveKitError(.invalidState, message: "Unknown LocalTrack type")
        }

        // Try to start the Track
        try await track.start()
        // Starting the Track could be time consuming especially for camera etc.
        // Check cancellation after track starts.
        try Task.checkCancellation()

        do {
            var dimensions: Dimensions? // Only for Video

            if let track = track as? LocalVideoTrack {
                // Wait for Dimensions...
                log("[Publish] Waiting for dimensions to resolve...")
                dimensions = try await track.capturer.dimensionsCompleter.wait()
            }

            let populatorFunc: SignalClient.AddTrackRequestPopulator<LKRTCRtpTransceiverInit> = { populator in

                let transInit = DispatchQueue.liveKitWebRTC.sync { LKRTCRtpTransceiverInit() }
                transInit.direction = .sendOnly

                if let track = track as? LocalVideoTrack {
                    guard let dimensions else {
                        throw LiveKitError(.capturerDimensionsNotResolved, message: "VideoCapturer dimensions are not resolved")
                    }

                    self.log("[publish] computing encode settings with dimensions: \(dimensions)...")

                    let publishOptions = (publishOptions as? VideoPublishOptions) ?? self.room._state.options.defaultVideoPublishOptions

                    let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                                publishOptions: publishOptions,
                                                                isScreenShare: track.source == .screenShareVideo)

                    self.log("[publish] using encodings: \(encodings)")
                    transInit.sendEncodings = encodings

                    let videoLayers = dimensions.videoLayers(for: encodings)

                    self.log("[publish] using layers: \(videoLayers.map { String(describing: $0) }.joined(separator: ", "))")

                    var simulcastCodecs: [Livekit_SimulcastCodec] = [
                        // Always add first codec...
                        Livekit_SimulcastCodec.with {
                            $0.cid = track.mediaTrack.trackId
                            if let preferredCodec = publishOptions.preferredCodec {
                                $0.codec = preferredCodec.id
                            }
                        },
                    ]

                    if let backupCodec = publishOptions.preferredBackupCodec {
                        // Add backup codec to simulcast codecs...
                        let lkSimulcastCodec = Livekit_SimulcastCodec.with {
                            $0.cid = ""
                            $0.codec = backupCodec.id
                        }
                        simulcastCodecs.append(lkSimulcastCodec)
                    }

                    populator.width = UInt32(dimensions.width)
                    populator.height = UInt32(dimensions.height)
                    populator.layers = videoLayers
                    populator.simulcastCodecs = simulcastCodecs

                    self.log("[publish] requesting add track to server with \(populator)...")

                } else if track is LocalAudioTrack {
                    // additional params for Audio
                    let publishOptions = (publishOptions as? AudioPublishOptions) ?? self.room._state.options.defaultAudioPublishOptions

                    populator.disableDtx = !publishOptions.dtx

                    let encoding = publishOptions.encoding ?? AudioEncoding.presetSpeech

                    self.log("[publish] maxBitrate: \(encoding.maxBitrate)")

                    transInit.sendEncodings = [
                        Engine.createRtpEncodingParameters(encoding: encoding),
                    ]
                }

                if let mediaPublishOptions = publishOptions as? MediaPublishOptions,
                   let streamName = mediaPublishOptions.streamName
                {
                    // Set stream name if specified in options
                    populator.stream = streamName
                }

                return transInit
            }

            // Request a new track to the server
            let addTrackResult = try await room.engine.signalClient.sendAddTrack(cid: track.mediaTrack.trackId,
                                                                                 name: track.name,
                                                                                 type: track.kind.toPBType(),
                                                                                 source: track.source.toPBType(),
                                                                                 encryption: room.e2eeManager?.e2eeOptions.encryptionType.toPBType() ?? .none,
                                                                                 populatorFunc)

            log("[Publish] server responded trackInfo: \(addTrackResult.trackInfo)")

            // Add transceiver to pc
            let transceiver = try publisher.addTransceiver(with: track.mediaTrack, transceiverInit: addTrackResult.result)
            log("[Publish] Added transceiver: \(addTrackResult.trackInfo)...")

            do {
                try await track.onPublish()

                // Store publishOptions used for this track...
                track._publishOptions = publishOptions

                // Attach sender to track...
                track.set(transport: publisher, rtpSender: transceiver.sender)

                if track is LocalVideoTrack {
                    if let firstCodecMime = addTrackResult.trackInfo.codecs.first?.mimeType,
                       let firstVideoCodec = try? VideoCodec.from(mimeType: firstCodecMime)
                    {
                        log("[Publish] First video codec: \(firstVideoCodec)")
                        track._videoCodec = firstVideoCodec
                    }

                    let publishOptions = (publishOptions as? VideoPublishOptions) ?? room._state.options.defaultVideoPublishOptions
                    // if screen share or simulcast is enabled,
                    // degrade resolution by using server's layer switching logic instead of WebRTC's logic
                    if track.source == .screenShareVideo || publishOptions.simulcast {
                        log("[publish] set degradationPreference to .maintainResolution")
                        let params = transceiver.sender.parameters
                        params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
                        // changing params directly doesn't work so we need to update params
                        // and set it back to sender.parameters
                        transceiver.sender.parameters = params
                    }

                    if let preferredCodec = publishOptions.preferredCodec {
                        transceiver.set(preferredVideoCodec: preferredCodec)
                    }
                }

                try await room.engine.publisherShouldNegotiate()
                try Task.checkCancellation()

            } catch {
                // Rollback
                track.set(transport: nil, rtpSender: nil)
                try publisher.remove(track: transceiver.sender)
                // Rethrow
                throw error
            }

            let publication = LocalTrackPublication(info: addTrackResult.trackInfo, track: track, participant: self)

            add(publication: publication)

            // Notify didPublish
            delegates.notify(label: { "localParticipant.didPublish \(publication)" }) {
                $0.participant?(self, didPublishTrack: publication)
            }
            room.delegates.notify(label: { "localParticipant.didPublish \(publication)" }) {
                $0.room?(self.room, participant: self, didPublishTrack: publication)
            }

            log("[publish] success \(publication)", .info)

            return publication
        } catch {
            log("[publish] failed \(track), error: \(error)", .error)
            // Stop track when publish fails
            try await track.stop()
            // Rethrow
            throw error
        }
    }

    /// publish a new audio track to the Room
    @objc
    @discardableResult
    public func publish(audioTrack: LocalAudioTrack, publishOptions: AudioPublishOptions? = nil) async throws -> LocalTrackPublication {
        try await publish(track: audioTrack, publishOptions: publishOptions)
    }

    /// publish a new video track to the Room
    @objc
    @discardableResult
    public func publish(videoTrack: LocalVideoTrack, publishOptions: VideoPublishOptions? = nil) async throws -> LocalTrackPublication {
        try await publish(track: videoTrack, publishOptions: publishOptions)
    }

    @objc
    override public func unpublishAll(notify _notify: Bool = true) async {
        // Build a list of Publications
        let publications = _state.trackPublications.values.compactMap { $0 as? LocalTrackPublication }
        for publication in publications {
            do {
                try await unpublish(publication: publication, notify: _notify)
            } catch {
                log("Failed to unpublish track \(publication.sid) with error \(error)", .error)
            }
        }
    }

    /// unpublish an existing published track
    /// this will also stop the track
    @objc
    public func unpublish(publication: LocalTrackPublication, notify _notify: Bool = true) async throws {
        func _notifyDidUnpublish() async {
            guard _notify else { return }
            delegates.notify(label: { "localParticipant.didUnpublish \(publication)" }) {
                $0.participant?(self, didUnpublishTrack: publication)
            }
            room.delegates.notify(label: { "room.didUnpublish \(publication)" }) {
                $0.room?(self.room, participant: self, didUnpublishTrack: publication)
            }
        }

        let engine = room.engine

        // Remove the publication
        _state.mutate { $0.trackPublications.removeValue(forKey: publication.sid) }

        // If track is nil, only notify unpublish and return
        guard let track = publication.track as? LocalTrack else {
            return await _notifyDidUnpublish()
        }

        // Wait for track to stop (if required)
        if room._state.options.stopLocalTrackOnUnpublish {
            try await track.stop()
        }

        if let publisher = engine.publisher, let sender = track.rtpSender {
            // Remove all simulcast senders...
            for simulcastSender in track._simulcastRtpSenders.values {
                try publisher.remove(track: simulcastSender)
            }
            // Remove main sender...
            try publisher.remove(track: sender)
            // Mark re-negotiation required...
            try await engine.publisherShouldNegotiate()
        }

        try await track.onUnpublish()

        await _notifyDidUnpublish()
    }

    /// Publish data to the other participants in the room
    ///
    /// Data is forwarded to each participant in the room. Each payload must not exceed 15k.
    /// - Parameters:
    ///   - data: Data to send
    ///   - options: Provide options with a ``DataPublishOptions`` class.
    @objc
    public func publish(data: Data, options: DataPublishOptions? = nil) async throws {
        let options = options ?? room._state.options.defaultDataPublishOptions

        let userPacket = Livekit_UserPacket.with {
            $0.participantSid = self.sid
            $0.payload = data
            $0.destinationIdentities = options.destinationIdentities
            $0.topic = options.topic ?? ""
        }

        try await room.engine.send(userPacket: userPacket, kind: options.reliable ? .reliable : .lossy)
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
    @objc
    public func setTrackSubscriptionPermissions(allParticipantsAllowed: Bool,
                                                trackPermissions: [ParticipantTrackPermission] = []) async throws
    {
        self.allParticipantsAllowed = allParticipantsAllowed
        self.trackPermissions = trackPermissions

        try await sendTrackSubscriptionPermissions()
    }

    /// Sets and updates the metadata of the local participant.
    ///
    /// Note: this requires `CanUpdateOwnMetadata` permission encoded in the token.
    public func set(metadata: String) async throws {
        // Mutate state to set metadata and copy name from state
        let name = _state.mutate {
            $0.metadata = metadata
            return $0.name
        }

        // TODO: Revert internal state on failure

        try await room.engine.signalClient.sendUpdateLocalMetadata(metadata, name: name)
    }

    /// Sets and updates the name of the local participant.
    ///
    /// Note: this requires `CanUpdateOwnMetadata` permission encoded in the token.
    public func set(name: String) async throws {
        // Mutate state to set name and copy metadata from state
        let metadata = _state.mutate {
            $0.name = name
            return $0.metadata
        }

        // TODO: Revert internal state on failure

        try await room.engine.signalClient.sendUpdateLocalMetadata(metadata ?? "", name: name)
    }

    func sendTrackSubscriptionPermissions() async throws {
        guard room.engine._state.connectionState == .connected else { return }

        try await room.engine.signalClient.sendUpdateSubscriptionPermission(allParticipants: allParticipantsAllowed,
                                                                            trackPermissions: trackPermissions)
    }

    func _set(subscribedQualities qualities: [Livekit_SubscribedQuality], forTrackSid trackSid: String) {
        guard let pub = getTrackPublication(sid: trackSid),
              let track = pub.track as? LocalVideoTrack,
              let sender = track.rtpSender
        else { return }

        sender._set(subscribedQualities: qualities)
    }

    override func set(permissions newValue: ParticipantPermissions) -> Bool {
        let didUpdate = super.set(permissions: newValue)

        if didUpdate {
            delegates.notify(label: { "participant.didUpdatePermissions: \(newValue)" }) {
                $0.participant?(self, didUpdatePermissions: newValue)
            }
            room.delegates.notify(label: { "room.didUpdatePermissions: \(newValue)" }) {
                $0.room?(self.room, participant: self, didUpdatePermissions: newValue)
            }
        }

        return didUpdate
    }
}

// MARK: - Session Migration

extension LocalParticipant {
    func publishedTracksInfo() -> [Livekit_TrackPublishedResponse] {
        _state.trackPublications.values.filter { $0.track != nil }
            .map { publication in
                Livekit_TrackPublishedResponse.with {
                    $0.cid = publication.track!.mediaTrack.trackId
                    if let info = publication._state.latestInfo {
                        $0.track = info
                    }
                }
            }
    }

    func republishTracks() async throws {
        let mediaTracks = _state.trackPublications.values.map { $0.track as? LocalTrack }.compactMap { $0 }

        await unpublishAll()

        for mediaTrack in mediaTracks {
            // Don't re-publish muted tracks
            if mediaTrack.isMuted { continue }
            try await publish(track: mediaTrack, publishOptions: mediaTrack.publishOptions)
        }
    }
}

// MARK: - Simplified API

public extension LocalParticipant {
    @objc
    @discardableResult
    func setCamera(enabled: Bool,
                   captureOptions: CameraCaptureOptions? = nil,
                   publishOptions: VideoPublishOptions? = nil) async throws -> LocalTrackPublication?
    {
        try await set(source: .camera,
                      enabled: enabled,
                      captureOptions: captureOptions,
                      publishOptions: publishOptions)
    }

    @objc
    @discardableResult
    func setMicrophone(enabled: Bool,
                       captureOptions: AudioCaptureOptions? = nil,
                       publishOptions: AudioPublishOptions? = nil) async throws -> LocalTrackPublication?
    {
        try await set(source: .microphone,
                      enabled: enabled,
                      captureOptions: captureOptions,
                      publishOptions: publishOptions)
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
    @objc
    @discardableResult
    func setScreenShare(enabled: Bool) async throws -> LocalTrackPublication? {
        try await set(source: .screenShareVideo, enabled: enabled)
    }

    @objc
    @discardableResult
    func set(source: Track.Source,
             enabled: Bool,
             captureOptions: CaptureOptions? = nil,
             publishOptions: PublishOptions? = nil) async throws -> LocalTrackPublication?
    {
        // Try to get existing publication
        if let publication = getTrackPublication(source: source) as? LocalTrackPublication {
            if enabled {
                try await publication.unmute()
                return publication
            } else {
                try await publication.mute()
                return publication
            }
        } else if enabled {
            // Try to create a new track
            if source == .camera {
                let localTrack = LocalVideoTrack.createCameraTrack(options: (captureOptions as? CameraCaptureOptions) ?? room._state.options.defaultCameraCaptureOptions,
                                                                   reportStatistics: room._state.options.reportRemoteTrackStatistics)
                return try await publish(videoTrack: localTrack, publishOptions: publishOptions as? VideoPublishOptions)
            } else if source == .microphone {
                let localTrack = LocalAudioTrack.createTrack(options: (captureOptions as? AudioCaptureOptions) ?? room._state.options.defaultAudioCaptureOptions,
                                                             reportStatistics: room._state.options.reportRemoteTrackStatistics)
                return try await publish(audioTrack: localTrack, publishOptions: publishOptions as? AudioPublishOptions)
            } else if source == .screenShareVideo {
                #if os(iOS)
                    let localTrack: LocalVideoTrack
                    let options = (captureOptions as? ScreenShareCaptureOptions) ?? room._state.options.defaultScreenShareCaptureOptions
                    if options.useBroadcastExtension {
                        let screenShareExtensionId = Bundle.main.infoDictionary?[BroadcastScreenCapturer.kRTCScreenSharingExtension] as? String
                        await RPSystemBroadcastPickerView.show(for: screenShareExtensionId, showsMicrophoneButton: false)
                        localTrack = LocalVideoTrack.createBroadcastScreenCapturerTrack(options: options)
                    } else {
                        localTrack = LocalVideoTrack.createInAppScreenShareTrack(options: options)
                    }
                    return try await publish(videoTrack: localTrack, publishOptions: publishOptions as? VideoPublishOptions)
                #elseif os(macOS)
                    if #available(macOS 12.3, *) {
                        let mainDisplay = try await MacOSScreenCapturer.mainDisplaySource()
                        let track = LocalVideoTrack.createMacOSScreenShareTrack(source: mainDisplay,
                                                                                options: (captureOptions as? ScreenShareCaptureOptions) ?? self.room._state.options.defaultScreenShareCaptureOptions,
                                                                                reportStatistics: room._state.options.reportRemoteTrackStatistics)
                        return try await publish(videoTrack: track, publishOptions: publishOptions as? VideoPublishOptions)
                    }
                #endif
            }
        }

        return nil
    }
}

// MARK: - Simulcast codecs

extension LocalParticipant {
    // Publish additional (backup) codec when requested by server
    func publish(additionalVideoCodec subscribedCodec: Livekit_SubscribedCodec,
                 for localTrackPublication: LocalTrackPublication) async throws
    {
        let videoCodec = try subscribedCodec.toVideoCodec()

        log("[Publish/Backup] Additional video codec: \(videoCodec)...")

        guard let track = localTrackPublication.track as? LocalVideoTrack else {
            throw LiveKitError(.invalidState, message: "Track is nil")
        }

        if !videoCodec.isBackup {
            throw LiveKitError(.invalidState, message: "Attempted to publish a non-backup video codec as backup")
        }

        let publisher = try room.engine.requirePublisher()

        let publishOptions = (track.publishOptions as? VideoPublishOptions) ?? room._state.options.defaultVideoPublishOptions

        // Should be already resolved...
        let dimensions = try await track.capturer.dimensionsCompleter.wait()

        let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                    publishOptions: publishOptions,
                                                    overrideVideoCodec: videoCodec)
        log("[Publish/Backup] Using encodings \(encodings)...")

        // Add transceiver first...

        let transInit = DispatchQueue.liveKitWebRTC.sync { LKRTCRtpTransceiverInit() }
        transInit.direction = .sendOnly
        transInit.sendEncodings = encodings

        // Add transceiver to publisher pc...
        let transceiver = try publisher.addTransceiver(with: track.mediaTrack, transceiverInit: transInit)
        log("[Publish] Added transceiver...")

        // Set codec...
        transceiver.set(preferredVideoCodec: videoCodec)

        let sender = transceiver.sender

        // Request a new track to the server
        let addTrackResult = try await room.engine.signalClient.sendAddTrack(cid: sender.senderId,
                                                                             name: track.name,
                                                                             type: track.kind.toPBType(),
                                                                             source: track.source.toPBType())
        {
            $0.sid = localTrackPublication.sid
            $0.simulcastCodecs = [
                Livekit_SimulcastCodec.with { sc in
                    sc.cid = sender.senderId
                    sc.codec = videoCodec.id
                },
            ]

            $0.layers = dimensions.videoLayers(for: encodings)
        }

        log("[Publish] server responded trackInfo: \(addTrackResult.trackInfo)")

        sender._set(subscribedQualities: subscribedCodec.qualities)

        // Attach multi-codec sender...
        track._simulcastRtpSenders[videoCodec] = sender

        try await room.engine.publisherShouldNegotiate()
    }
}

// MARK: - Helper

extension [Livekit_SubscribedQuality] {
    /// Find the highest quality in the array
    var highest: Livekit_VideoQuality {
        reduce(Livekit_VideoQuality.off) { maxQuality, subscribedQuality in
            subscribedQuality.enabled && subscribedQuality.quality > maxQuality ? subscribedQuality.quality : maxQuality
        }
    }
}
