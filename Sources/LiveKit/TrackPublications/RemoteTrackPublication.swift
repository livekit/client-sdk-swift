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

import CoreGraphics
import Foundation

@_implementationOnly import WebRTC

@objc
public enum SubscriptionState: Int, Codable {
    case subscribed
    case notAllowed
    case unsubscribed
}

@objc
public class RemoteTrackPublication: TrackPublication {
    // MARK: - Public

    @objc
    public var isSubscriptionAllowed: Bool { _state.isSubscriptionAllowed }

    @objc
    public var isEnabled: Bool { _state.trackSettings.isEnabled }

    override public var isMuted: Bool { track?.isMuted ?? _state.isMetadataMuted }

    // MARK: - Private

    // adaptiveStream
    // this must be on .main queue
    private var asTimer = DispatchQueueTimer(timeInterval: 0.3, queue: .main)

    override init(info: Livekit_TrackInfo,
                  track: Track? = nil,
                  participant: Participant)
    {
        super.init(info: info,
                   track: track,
                   participant: participant)

        asTimer.handler = { [weak self] in self?.onAdaptiveStreamTimer() }
    }

    deinit {
        asTimer.suspend()
    }

    override func updateFromInfo(info: Livekit_TrackInfo) {
        super.updateFromInfo(info: info)
        track?.set(muted: info.muted)
        set(metadataMuted: info.muted)
    }

    override public var isSubscribed: Bool {
        if !isSubscriptionAllowed { return false }
        return _state.isSubscribePreferred != false && super.isSubscribed
    }

    @objc
    public var subscriptionState: SubscriptionState {
        if !isSubscriptionAllowed { return .notAllowed }
        return isSubscribed ? .subscribed : .unsubscribed
    }

    /// Subscribe or unsubscribe from this track.
    @objc
    public func set(subscribed newValue: Bool) async throws {
        guard _state.isSubscribePreferred != newValue else { return }

        let participant = try await requireParticipant()

        _state.mutate { $0.isSubscribePreferred = newValue }

        try await participant.room.engine.signalClient.sendUpdateSubscription(participantSid: participant.sid,
                                                                              trackSid: sid,
                                                                              isSubscribed: newValue)
    }

    /// Enable or disable server from sending down data for this track.
    ///
    /// This is useful when the participant is off screen, you may disable streaming down their video to reduce bandwidth requirements.
    @objc
    public func set(enabled newValue: Bool) async throws {
        // No-op if already the desired value
        let trackSettings = _state.trackSettings
        guard trackSettings.isEnabled != newValue else { return }

        try await checkUserCanModifyTrackSettings()

        let settings = trackSettings.copyWith(isEnabled: newValue)
        // Attempt to set the new settings
        try await send(trackSettings: settings)
    }

    /// Set preferred video FPS for this track.
    @objc
    public func set(preferredFPS newValue: UInt) async throws {
        // No-op if already the desired value
        let trackSettings = _state.trackSettings
        guard trackSettings.preferredFPS != newValue else { return }

        try await checkUserCanModifyTrackSettings()

        let settings = trackSettings.copyWith(preferredFPS: newValue)
        // Attempt to set the new settings
        try await send(trackSettings: settings)
    }

    /// Set preferred video dimensions for this track.
    ///
    /// Based on this value, server will decide which layer to send.
    /// Use ``RemoteTrackPublication/set(videoQuality:)`` to explicitly set layer instead.
    @objc
    public func set(preferredDimensions newValue: Dimensions) async throws {
        // No-op if already the desired value
        let trackSettings = _state.trackSettings
        guard trackSettings.dimensions != newValue else { return }

        try await checkUserCanModifyTrackSettings()

        let settings = trackSettings.copyWith(
            dimensions: newValue,
            videoQuality: nil
        )
        // Attempt to set the new settings
        try await send(trackSettings: settings)
    }

    /// For tracks that support simulcasting, adjust subscribed quality.
    ///
    /// This indicates the highest quality the client can accept. if network
    /// bandwidth does not allow, server will automatically reduce quality to
    /// optimize for uninterrupted video.
    @objc
    public func set(videoQuality newValue: VideoQuality) async throws {
        // No-op if already the desired value
        let trackSettings = _state.trackSettings
        guard trackSettings.videoQuality != newValue else { return }

        try await checkUserCanModifyTrackSettings()

        let settings = trackSettings.copyWith(
            dimensions: nil,
            videoQuality: newValue
        )
        // Attempt to set the new settings
        try await send(trackSettings: settings)
    }

    @discardableResult
    override func set(track newValue: Track?) -> Track? {
        log("RemoteTrackPublication set track: \(String(describing: newValue))")

        let oldValue = super.set(track: newValue)
        if newValue != oldValue {
            // always suspend adaptiveStream timer first
            asTimer.suspend()

            if let newValue {
                // Copy meta-data to track
                newValue._state.mutate {
                    $0.sid = sid
                    $0.dimensions = $0.dimensions == nil ? dimensions : $0.dimensions
                }

                // reset track settings, track is initially disabled only if adaptive stream and is a video track
                resetTrackSettings()

                log("[adaptiveStream] did reset trackSettings: \(_state.trackSettings), kind: \(newValue.kind)")

                // start adaptiveStream timer only if it's a video track
                if isAdaptiveStreamEnabled {
                    asTimer.restart()
                }

                // if new Track has been set to this RemoteTrackPublication,
                // update the Track's muted state from the latest info.
                newValue.set(muted: _state.isMetadataMuted,
                             notify: false)
            }

            if oldValue != nil, newValue == nil, let participant = participant as? RemoteParticipant {
                participant.delegates.notify(label: { "participant.didUnsubscribe \(self)" }) {
                    $0.participant?(participant, didUnsubscribeTrack: self)
                }
                participant.room.delegates.notify(label: { "room.didUnsubscribe \(self)" }) {
                    $0.room?(participant.room, participant: participant, didUnsubscribeTrack: self)
                }
            }
        }

        return oldValue
    }
}

// MARK: - Private

private extension RemoteTrackPublication {
    var isAdaptiveStreamEnabled: Bool { (participant?.room._state.options ?? RoomOptions()).adaptiveStream && kind == .video }

    var engineConnectionState: ConnectionState {
        guard let participant else {
            log("Participant is nil", .warning)
            return .disconnected
        }

        return participant.room.engine._state.connectionState
    }

    func checkUserCanModifyTrackSettings() async throws {
        // adaptiveStream must be disabled and must be subscribed
        if isAdaptiveStreamEnabled || !isSubscribed {
            throw LiveKitError(.invalidState, message: "adaptiveStream must be disabled and track must be subscribed")
        }
    }
}

// MARK: - Internal

extension RemoteTrackPublication {
    func set(metadataMuted newValue: Bool) {
        guard _state.isMetadataMuted != newValue else { return }

        guard let participant else {
            log("Participant is nil", .warning)
            return
        }

        _state.mutate { $0.isMetadataMuted = newValue }

        // if track exists, track will emit the following events
        if track == nil {
            participant.delegates.notify(label: { "participant.didUpdatePublication isMuted: \(newValue)" }) {
                $0.participant?(participant, track: self, didUpdateIsMuted: newValue)
            }
            participant.room.delegates.notify(label: { "room.didUpdatePublication isMuted: \(newValue)" }) {
                $0.room?(participant.room, participant: participant, track: self, didUpdateIsMuted: newValue)
            }
        }
    }

    func set(subscriptionAllowed newValue: Bool) {
        guard _state.isSubscriptionAllowed != newValue else { return }
        _state.mutate { $0.isSubscriptionAllowed = newValue }

        guard let participant = participant as? RemoteParticipant else { return }
        participant.delegates.notify(label: { "participant.didUpdate permission: \(newValue)" }) {
            $0.participant?(participant, track: self, didUpdateIsSubscriptionAllowed: newValue)
        }
        participant.room.delegates.notify(label: { "room.didUpdate permission: \(newValue)" }) {
            $0.room?(participant.room, participant: participant, track: self, didUpdateIsSubscriptionAllowed: newValue)
        }
    }
}

// MARK: - TrackSettings

extension RemoteTrackPublication {
    // reset track settings
    func resetTrackSettings() {
        // track is initially disabled when adaptive stream is enabled
        let initiallyEnabled = !isAdaptiveStreamEnabled
        _state.mutate { $0.trackSettings = TrackSettings(enabled: initiallyEnabled) }
    }

    // attempt to send track settings
    func send(trackSettings newValue: TrackSettings) async throws {
        let participant = try await requireParticipant()

        log("[adaptiveStream] sending \(newValue), sid: \(sid)")

        let state = _state.copy()

        assert(!state.isSendingTrackSettings, "send(trackSettings:) called while previous send not completed")

        if state.isSendingTrackSettings {
            // Previous send hasn't completed yet...
            throw LiveKitError(.invalidState, message: "Already busy sending new track settings")
        }

        // update state
        _state.mutate {
            $0.trackSettings = newValue
            $0.isSendingTrackSettings = true
        }

        // Attempt to set the new settings
        do {
            try await participant.room.engine.signalClient.sendUpdateTrackSettings(sid: sid, settings: newValue)
            _state.mutate { $0.isSendingTrackSettings = false }
        } catch {
            // Revert track settings on failure
            _state.mutate {
                $0.trackSettings = state.trackSettings
                $0.isSendingTrackSettings = false
            }

            log("Failed to send track settings: \(newValue), sid: \(sid), error: \(error)")
        }
    }
}

// MARK: - Adaptive Stream

extension Collection<VideoRenderer> {
    func containsOneOrMoreAdaptiveStreamEnabledRenderers() -> Bool {
        // not visible if no entry
        if isEmpty { return false }
        // at least 1 entry should be visible
        return contains { $0.isAdaptiveStreamEnabled }
    }

    func largestSize() -> CGSize? {
        func maxCGSize(_ s1: CGSize, _ s2: CGSize) -> CGSize {
            CGSize(width: Swift.max(s1.width, s2.width),
                   height: Swift.max(s1.height, s2.height))
        }

        // use post-layout nativeRenderer's view size otherwise return nil
        // which results lower layer to be requested (enabled: true, dimensions: 0x0)
        return filter(\.isAdaptiveStreamEnabled)
            .compactMap { $0.adaptiveStreamSize != .zero ? $0.adaptiveStreamSize : nil }
            .reduce(into: nil as CGSize?) { previous, current in
                guard let unwrappedPrevious = previous else {
                    previous = current
                    return
                }
                previous = maxCGSize(unwrappedPrevious, current)
            }
    }
}

extension RemoteTrackPublication {
    // executed on .main
    private func onAdaptiveStreamTimer() {
        // this should never happen
        assert(Thread.current.isMainThread, "this method must be called from main thread")

        // suspend timer first
        asTimer.suspend()

        // don't continue if the engine is disconnected
        guard engineConnectionState != .disconnected else {
            log("engine is disconnected")
            return
        }

        let videoRenderers = track?.videoRenderers.allObjects ?? []
        let isEnabled = videoRenderers.containsOneOrMoreAdaptiveStreamEnabledRenderers()
        var dimensions: Dimensions = .zero

        // compute the largest video view size
        if isEnabled, let maxSize = videoRenderers.largestSize() {
            dimensions = Dimensions(width: Int32(ceil(maxSize.width)),
                                    height: Int32(ceil(maxSize.height)))
        }

        let newSettings = _state.trackSettings.copyWith(isEnabled: isEnabled, dimensions: dimensions)

        guard _state.trackSettings != newSettings else {
            // no settings updated
            asTimer.resume()
            return
        }

        // keep old settings
        let oldSettings = _state.trackSettings
        // update state
        _state.mutate { $0.trackSettings = newSettings }

        // log when flipping from enabled -> disabled
        if oldSettings.isEnabled, !newSettings.isEnabled {
            let viewsString = videoRenderers.enumerated().map { i, v in "videoRenderer\(i)(adaptiveStreamIsEnabled: \(v.isAdaptiveStreamEnabled), adaptiveStreamSize: \(v.adaptiveStreamSize))" }.joined(separator: ", ")
            log("[adaptiveStream] disabling sid: \(sid), videoRenderersCount: \(videoRenderers.count), \(viewsString)")
        }

        if let videoTrack = track?.mediaTrack as? LKRTCVideoTrack {
            log("VideoTrack.shouldReceive: \(isEnabled)")
            DispatchQueue.liveKitWebRTC.sync { videoTrack.shouldReceive = isEnabled }
        }

        Task {
            do {
                try await send(trackSettings: newSettings)
            } catch {
                // Revert to old settings on failure
                _state.mutate { $0.trackSettings = oldSettings }
                log("[adaptiveStream] failed to send trackSettings, sid: \(self.sid) error: \(error)", .error)
            }

            asTimer.restart()
        }
    }
}
