/*
 * Copyright 2026 LiveKit
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

// swiftlint:disable file_length

#if !COCOAPODS && !LK_XCFRAMEWORK
import LiveKitNanopb
#endif
internal import LiveKitWebRTC
import Combine
import Foundation

@objcMembers
public class LocalParticipant: Participant, @unchecked Sendable {
    public var localAudioTracks: [LocalTrackPublication] { audioTracks.compactMap { $0 as? LocalTrackPublication } }

    public var localVideoTracks: [LocalTrackPublication] { videoTracks.compactMap { $0 as? LocalTrackPublication } }

    private var allParticipantsAllowed: Bool = true

    private var trackPermissions: [ParticipantTrackPermission] = []

    /// publish a new audio track to the Room
    @discardableResult
    public func publish(audioTrack: LocalAudioTrack, options: AudioPublishOptions? = nil) async throws -> LocalTrackPublication {
        let result = try await _publishSerialRunner.run {
            try await self._publish(track: audioTrack, options: options)
        }
        guard let result else { throw LiveKitError(.invalidState) }
        return result
    }

    /// publish a new video track to the Room
    @discardableResult
    public func publish(videoTrack: LocalVideoTrack, options: VideoPublishOptions? = nil) async throws -> LocalTrackPublication {
        let result = try await _publishSerialRunner.run {
            try await self._publish(track: videoTrack, options: options)
        }
        guard let result else { throw LiveKitError(.invalidState) }
        return result
    }

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
    public func unpublish(publication: LocalTrackPublication, notify _notify: Bool = true) async throws {
        try await _unpublish(publication: publication, notify: _notify, stopTrack: true)
    }

    func _unpublish(publication: LocalTrackPublication, notify _notify: Bool, stopTrack: Bool) async throws {
        let room = try requireRoom()

        func _notifyDidUnpublish() async {
            guard _notify else { return }
            delegates.notify(label: { "localParticipant.didUnpublish \(publication)" }) {
                $0.participant?(self, didUnpublishTrack: publication)
            }
            room.delegates.notify(label: { "room.didUnpublish \(publication)" }) {
                $0.room?(room, participant: self, didUnpublishTrack: publication)
            }
        }

        if let native = publication.track?.nativePublication.copy() {
            try await native.unpublish()
            publication.track?.cancelStatisticsTimer()
            if stopTrack, room._state.roomOptions.stopLocalTrackOnUnpublish, let audio = publication.track as? LocalAudioTrack {
                try await audio.nativeAudio.copy()?.release()
                audio.nativeAudio.mutate { $0 = nil }
            }
            if stopTrack, room._state.roomOptions.stopLocalTrackOnUnpublish, let video = publication.track as? LocalVideoTrack {
                video.nativeCapture.mutate { $0 = nil }
                try await video.nativeVideo.copy()?.release()
                video.nativeVideo.mutate { $0 = nil }
                try await video.stop()
            }
            publication.track?.nativePublication.mutate { $0 = nil }
            publication.track?._state.mutate {
                $0.publishState = .unpublished
                if stopTrack, room._state.roomOptions.stopLocalTrackOnUnpublish { $0.trackState = .stopped }
            }
            _state.mutate { $0.trackPublications.removeValue(forKey: publication.sid) }
            await _notifyDidUnpublish()
            return
        }

        // Remove the publication
        _state.mutate { $0.trackPublications.removeValue(forKey: publication.sid) }

        // If track is nil, only notify unpublish and return
        guard let track = publication.track as? LocalTrack else {
            return await _notifyDidUnpublish()
        }

        // Wait for track to stop (if required)
        if stopTrack, room._state.roomOptions.stopLocalTrackOnUnpublish {
            try await track.stop()
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
    /// - Note: The default (`reliable: false`) sends over the lossy channel, which under sustained
    ///   backpressure drops the oldest queued payload in favour of newer ones — the call returns
    ///   normally in that case. ``RoomDelegate/room(_:didUpdateBufferStatus:of:)`` reports when a
    ///   channel's buffer fills and drains, for callers that want to back off.
    public func publish(data: Data, options: DataPublishOptions? = nil) async throws {
        let room = try requireRoom()
        let options = options ?? room._state.roomOptions.defaultDataPublishOptions

        guard let identityString = _state.identity?.stringValue else {
            throw LiveKitError(.invalidState, message: "identity is nil")
        }

        let userPacket = Livekit_UserPacket.with {
            $0.participantIdentity = identityString
            $0.payload = data
            $0.destinationIdentities = options.destinationIdentities.map(\.stringValue)
            $0.topic = options.topic ?? ""
        }

        try await room.send(userPacket: userPacket, kind: options.reliable ? .reliable : .lossy)
    }

    /// Publish a SIP DTMF message to the room.
    ///
    /// Use this when a connected LiveKit SIP call needs keypad input, such as
    /// selecting an IVR menu option or dialing an extension.
    ///
    /// ```swift
    /// try await room.localParticipant.publishDtmf(code: 1, digit: "1")
    /// try await room.localParticipant.publishDtmf(code: 10, digit: "*")
    /// try await room.localParticipant.publishDtmf(code: 11, digit: "#")
    /// ```
    ///
    /// - Parameters:
    ///   - code: Numeric DTMF code. SIP calls commonly use `10` for `*` and `11` for `#`.
    ///   - digit: Human-readable DTMF digit, such as `"1"`, `"*"`, or `"#"`.
    public func publishDtmf(code: UInt32, digit: String) async throws {
        let room = try requireRoom()

        let packet = Livekit_DataPacket.with {
            $0.kind = .reliable
            $0.sipDtmf = Livekit_SipDTMF.with {
                $0.code = code
                $0.digit = digit
            }
        }

        try await room.send(dataPacket: packet)
    }

    // swiftformat:disable unusedArguments

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
                                                trackPermissions: [ParticipantTrackPermission] = []) async throws
    {
        throw LiveKitError(.invalidState, message: "Track subscription permissions are not exported by this native artifact")
    }

    // swiftformat:enable unusedArguments

    /// Sets and updates the metadata of the local participant.
    ///
    /// Note: this requires `CanUpdateOwnMetadata` permission encoded in the token.
    public func set(metadata: String) async throws {
        let room = try requireRoom()
        do { try await room.requireNativeSession().setMetadata(metadata: metadata) } catch { throw LiveKitError.mappingNative(error) }
        _state.mutate { $0.metadata = metadata }
    }

    /// Sets and updates the name of the local participant.
    ///
    /// Note: this requires `CanUpdateOwnMetadata` permission encoded in the token.
    public func set(name: String) async throws {
        let room = try requireRoom()
        do { try await room.requireNativeSession().setName(name: name) } catch { throw LiveKitError.mappingNative(error) }
        _state.mutate { $0.name = name }
    }

    public func set(attributes: [String: String]) async throws {
        let room = try requireRoom()
        do { try await room.requireNativeSession().setAttributes(attributes: attributes) } catch { throw LiveKitError.mappingNative(error) }
        _state.mutate { $0.attributes = attributes }
    }

    func sendTrackSubscriptionPermissions() async throws {
        let room = try requireRoom()
        guard room._state.connectionState == .connected else { return }

        try await room.signalClient.sendUpdateSubscriptionPermission(allParticipants: allParticipantsAllowed,
                                                                     trackPermissions: trackPermissions)
    }

    @RTC
    func _set(subscribedQualities qualities: [Livekit_SubscribedQuality], forTrackSid trackSid: Track.Sid) {
        guard let publication = trackPublications[trackSid],
              let track = publication.track as? LocalVideoTrack,
              let sender = track._state.rtpSender
        else { return }

        // Apply the merged list, not the incoming one: a re-apply can only replay what is cached,
        // so feeding the sender anything else would make the two paths disagree.
        let cached = track._state.read { $0.subscribedQualities }
        let merged = cached.merged(with: qualities)
        // The server restates unchanged qualities after every answer, and every mutate notifies
        // the track's delegates synchronously, inside the lock.
        if !merged.sameState(as: cached) {
            track._state.mutate { $0.subscribedQualities = merged }
        }
        sender.raw._set(subscribedQualities: merged)
    }

    /// Re-applies the last known dynacast state to every local video sender.
    ///
    /// Applying a publisher answer re-enables every encoding, and the server only ever reports
    /// qualities that *changed*, so without this the layers dynacast paused stay unpaused.
    func refreshSubscribedQualities() async {
        for publication in localVideoTracks {
            guard let track = publication.track as? LocalVideoTrack else { continue }

            // Reading before the hop is safe because SignalClient delivers every callback through
            // one AsyncSerialDelegate, so a quality update cannot land between here and the apply.
            let (qualities, qualitiesForCodec) = track._state.read { ($0.subscribedQualities, $0.subscribedQualitiesForCodec) }
            // Early-out before the hop: @RTC blocks, and this runs on every renegotiation.
            guard !qualities.isEmpty || !qualitiesForCodec.isEmpty else { continue }

            await RTC.run {
                for (videoCodec, codecQualities) in qualitiesForCodec {
                    let subscribedCodec = Livekit_SubscribedCodec.with {
                        $0.codec = videoCodec.name
                        $0.qualities = codecQualities
                    }
                    do {
                        let didUpdate = try track._set(subscribedCodec: subscribedCodec)
                        if !didUpdate {
                            track.log("No sender for cached codec: \(videoCodec.name)")
                        }
                    } catch {
                        track.log("Failed to refresh qualities for codec: \(videoCodec.name), error: \(error)")
                    }
                }

                if !qualities.isEmpty, let sender = track._state.rtpSender {
                    sender.raw._set(subscribedQualities: qualities)
                }
            }
        }
    }

    override func set(info: Livekit_ParticipantInfo, connectionState: ConnectionState) {
        super.set(info: info, connectionState: connectionState)

        for trackInfo in info.tracks {
            guard let publication = trackPublications[Track.Sid(from: trackInfo.sid)] as? LocalTrackPublication else { continue }
            publication.updateFromInfo(info: trackInfo)
            publication.track?.set(muted: trackInfo.muted)
        }
    }

    override func set(permissions newValue: ParticipantPermissions) -> Bool {
        guard let room = _room else { return false }
        let didUpdate = super.set(permissions: newValue)

        if didUpdate {
            delegates.notify(label: { "participant.didUpdatePermissions: \(newValue)" }) {
                $0.participant?(self, didUpdatePermissions: newValue)
            }
            room.delegates.notify(label: { "room.didUpdatePermissions: \(newValue)" }) {
                $0.room?(room, participant: self, didUpdatePermissions: newValue)
            }
        }

        return didUpdate
    }

    override public func isMicrophoneEnabled() -> Bool {
        if let room = _room, let recorder = room.preConnectBuffer.recorder, recorder.isRecording {
            true
        } else {
            super.isMicrophoneEnabled()
        }
    }

    // MARK: - Broadcast Activation

    #if os(iOS)

    private var cancellable = Set<AnyCancellable>()

    /// The screen capturer of a publish that is still waiting on the system content picker.
    private let _pendingScreenCapturer = StateSync<VideoCapturer?>(nil)

    override init(room: Room, sid: Participant.Sid? = nil, identity: Participant.Identity? = nil) {
        super.init(room: room, sid: sid, identity: identity)

        guard BroadcastBundleInfo.hasExtension else { return }
        BroadcastManager.shared.isBroadcastingPublisher.sink { [weak self] in
            self?.broadcastStateChanged($0)
        }
        .store(in: &cancellable)
    }

    private func broadcastStateChanged(_ isBroadcasting: Bool) {
        guard isBroadcasting else {
            log("Broadcast stopped", .debug)
            return
        }
        log("Broadcast started", .debug)

        Task { [weak self] in
            guard let self else { return }

            guard BroadcastManager.shared.shouldPublishTrack else {
                log("Will not publish screen share track", .debug)
                return
            }
            guard let room = _room, room.connectionState != .disconnected else {
                log("Room is disconnected, will not publish screen share track", .warning)
                return
            }
            do {
                try await set(source: .screenShareVideo, enabled: true, captureOptions: nil, publishOptions: nil, forBroadcastStart: true)
            } catch {
                log("Failed to enable screen share: \(error)", .error)
                BroadcastManager.shared.requestStop()
            }
        }
    }
    #endif
}

// MARK: - Session Migration

extension LocalParticipant {
    func publishedTracksInfo() -> [Livekit_TrackPublishedResponse] {
        _state.trackPublications.values.filter { $0.track != nil }
            .map { publication in
                Livekit_TrackPublishedResponse.with {
                    $0.cid = publication.track?.mediaTrack?.trackId ?? publication.sid.stringValue
                    if let info = publication._state.latestInfo {
                        $0.track = info
                    }
                }
            }
    }

    func republishAllTracks() async throws {
        let publications = _state.trackPublications.values.compactMap { $0 as? LocalTrackPublication }
        let mediaTracks = publications.compactMap { $0.track as? LocalTrack }

        for publication in publications {
            // Screen share capture sources (broadcast extension IPC, ReplayKit) cannot be
            // restarted programmatically, so keep them capturing until re-published.
            let isScreenShare = publication.source == .screenShareVideo
                || (publication.source == .unknown && publication.kind == .video && publication.name == Track.screenShareVideoName)
            let keepCapturing = isScreenShare && !(publication.track?.isMuted ?? true)
            do {
                try await _unpublish(publication: publication, notify: true, stopTrack: !keepCapturing)
                if keepCapturing {
                    await publication.set(track: nil)
                }
            } catch {
                log("Failed to unpublish track \(publication.sid) with error \(error)", .error)
            }
        }

        var firstError: Error?

        for mediaTrack in mediaTracks {
            // Don't re-publish muted tracks
            if mediaTrack.isMuted { continue }
            do {
                try await _publish(track: mediaTrack, options: mediaTrack.publishOptions)
            } catch {
                log("Failed to re-publish \(mediaTrack.source) track, error: \(error)", .error)
                firstError = firstError ?? error
            }
        }

        if let firstError { throw firstError }
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
    /// On iOS 27 and later, this uses ``IOSScreenCapturer``: content is picked through the system picker and captured
    /// in-process via ScreenCaptureKit, with no Broadcast Upload Extension or app group. Enabling screen share does not
    /// complete until the user has chosen what to share, and throws if they dismiss the picker.
    /// Set ``ScreenShareCaptureOptions/useScreenCaptureKit`` to `false` to keep the ReplayKit paths below on iOS 27.
    ///
    /// On earlier iOS versions, this uses ``InAppScreenCapturer`` to capture in-app screen only due to Apple's limitation;
    /// to capture the screen while the app is in the background, you will need to create a "Broadcast Upload Extension".
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
             publishOptions: TrackPublishOptions? = nil) async throws -> LocalTrackPublication?
    {
        try await set(source: source, enabled: enabled, captureOptions: captureOptions, publishOptions: publishOptions, forBroadcastStart: false)
    }

    /// - Parameter forBroadcastStart: The broadcast extension just started a broadcast, so a screen share
    ///   publishes that broadcast rather than presenting the ScreenCaptureKit picker.
    @nonobjc
    @discardableResult
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    internal func set(source: Track.Source,
                      enabled: Bool,
                      captureOptions: CaptureOptions?,
                      publishOptions: TrackPublishOptions?,
                      forBroadcastStart: Bool) async throws -> LocalTrackPublication?
    {
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(ScreenCaptureKit)
        // An unanswered content picker holds the serial runner, so stopping has to reach past it.
        // Only this participant's own pending pick is cancelled; the picker is process-wide.
        if source == .screenShareVideo, !enabled, #available(iOS 27.0, *),
           let capturer = _pendingScreenCapturer.read({ $0 }) as? IOSScreenCapturer
        {
            capturer.cancelPendingPick()
        }
        #endif

        return try await _publishSerialRunner.run {
            let room = try self.requireRoom()

            #if os(iOS)
            // The broadcast can stop while this publish waits behind another one.
            if forBroadcastStart, !BroadcastManager.shared.isBroadcasting {
                self.log("Broadcast stopped before its screen share was published", .debug)
                return nil
            }
            #endif

            // Try to get existing publication
            if let publication = self.getTrackPublication(source: source) as? LocalTrackPublication {
                if enabled {
                    try await publication.unmute()
                    return publication
                } else {
                    if source == .camera || source == .microphone {
                        try await publication.mute()
                    } else {
                        try await self.unpublish(publication: publication)
                    }
                    return publication
                }
            } else if enabled {
                // Try to create a new track
                if source == .camera {
                    let localTrack = await LocalVideoTrack.createCameraTrack(options: (captureOptions as? CameraCaptureOptions) ?? room._state.roomOptions.defaultCameraCaptureOptions,
                                                                             reportStatistics: room._state.roomOptions.reportRemoteTrackStatistics)
                    return try await self._publish(track: localTrack, options: publishOptions)
                } else if source == .microphone {
                    let localTrack = await LocalAudioTrack.createTrack(options: (captureOptions as? AudioCaptureOptions) ?? room._state.roomOptions.defaultAudioCaptureOptions,
                                                                       reportStatistics: room._state.roomOptions.reportRemoteTrackStatistics)
                    return try await self._publish(track: localTrack, options: publishOptions)
                } else if source == .screenShareVideo {
                    #if os(iOS)

                    let localTrack: LocalVideoTrack
                    let defaultOptions = room._state.roomOptions.defaultScreenShareCaptureOptions

                    // Preferred on iOS 27+, falling through to the ReplayKit modes below when it is
                    // turned off or the system picker cannot be presented.
                    #if !targetEnvironment(macCatalyst) && canImport(ScreenCaptureKit)
                    if #available(iOS 27.0, *) {
                        let options = (captureOptions as? ScreenShareCaptureOptions) ?? defaultOptions
                        if options.prefersScreenCaptureKit(roomDefaults: defaultOptions, publishesRunningBroadcast: forBroadcastStart) {
                            if await IOSScreenCapturer.isAvailable {
                                let track = await LocalVideoTrack.createIOSScreenShareTrack(options: options,
                                                                                            reportStatistics: room._state.roomOptions.reportRemoteTrackStatistics)
                                self._pendingScreenCapturer.mutate { $0 = track.capturer }
                                defer { self._pendingScreenCapturer.mutate { $0 = nil } }
                                return try await self._publish(track: track, options: publishOptions)
                            }
                            self.log("ScreenCaptureKit is unavailable, falling back to ReplayKit", .warning)
                        }
                    }
                    #endif

                    if defaultOptions.useBroadcastExtension {
                        if captureOptions != nil {
                            self.log("Ignoring screen capture options passed to local participant's `\(#function)`; using room defaults instead.", .warning)
                            self.log("When using a broadcast extension, screen capture options must be set as room defaults.", .warning)
                        }
                        guard BroadcastManager.shared.isBroadcasting else {
                            BroadcastManager.shared.requestActivation()
                            return nil
                        }
                        // Wait until broadcasting to publish track
                        localTrack = await LocalVideoTrack.createBroadcastScreenCapturerTrack(options: defaultOptions,
                                                                                              reportStatistics: room._state.roomOptions.reportRemoteTrackStatistics)
                    } else {
                        let options = (captureOptions as? ScreenShareCaptureOptions) ?? defaultOptions
                        localTrack = await LocalVideoTrack.createInAppScreenShareTrack(options: options)
                    }
                    return try await self._publish(track: localTrack, options: publishOptions)
                    #elseif os(macOS)
                    if #available(macOS 12.3, *) {
                        let mainDisplay = try await MacOSScreenCapturer.mainDisplaySource()
                        let track = await LocalVideoTrack.createMacOSScreenShareTrack(source: mainDisplay,
                                                                                      options: (captureOptions as? ScreenShareCaptureOptions) ?? room._state.roomOptions.defaultScreenShareCaptureOptions,
                                                                                      reportStatistics: room._state.roomOptions.reportRemoteTrackStatistics)
                        return try await self._publish(track: track, options: publishOptions)
                    }
                    #endif
                }
            }

            return nil
        }
    }
}

// MARK: - Simulcast codecs

extension LocalParticipant {
    // Publish additional (backup) codec when requested by server
    func publish(additionalVideoCodec _: Livekit_SubscribedCodec,
                 for _: LocalTrackPublication) async throws
    {
        throw LiveKitError(.invalidState, message: "Additional native video codec controls are not exported")
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

    /// Whether both lists describe the same subscription state.
    ///
    /// Cheaper than `==`, which compares whole messages by re-serializing both sides.
    func sameState(as other: [Livekit_SubscribedQuality]) -> Bool {
        elementsEqual(other) { $0.quality == $1.quality && $0.enabled == $1.enabled }
    }

    /// This list updated with `update`, replacing matching qualities in place and appending new ones.
    ///
    /// A `SubscribedQualityUpdate` only carries the qualities that changed, so replacing the list
    /// wholesale would forget the pause state of every layer the server did not mention. Entries are
    /// owned rather than kept as views, since the result outlives the message it arrived in.
    func merged(with update: [Livekit_SubscribedQuality]) -> [Livekit_SubscribedQuality] {
        var result = self
        for updated in update.map({ $0.owned() }) {
            if let index = result.firstIndex(where: { $0.quality == updated.quality }) {
                result[index] = updated
            } else {
                result.append(updated)
            }
        }
        return result
    }
}

// MARK: - Private

extension LocalParticipant {
    @discardableResult
    func _publish(track: LocalTrack, options: TrackPublishOptions? = nil) async throws -> LocalTrackPublication {
        try checkPermissions(toPublish: track)
        return try await publishNative(track: track, options: options)
    }

    private func checkPermissions(toPublish track: LocalTrack) throws {
        guard permissions.canPublish else {
            throw LiveKitError(.insufficientPermissions, message: "Participant does not have permission to publish")
        }

        let sources = permissions.canPublishSources
        if !sources.isEmpty, !sources.contains(track.source.rawValue) {
            throw LiveKitError(.insufficientPermissions, message: "Participant does not have permission to publish tracks from this source")
        }
    }
}

extension LocalParticipant {
    var isFastPublishMode: Bool {
        !_internalState.enabledPublishVideoCodecs.isEmpty
    }
}
