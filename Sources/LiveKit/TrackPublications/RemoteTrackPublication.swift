/*
 * Copyright 2022 LiveKit
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
import CoreGraphics

@_implementationOnly import WebRTC

@objc
public enum SubscriptionState: Int, Codable {
    case subscribed
    case notAllowed
    case unsubscribed
}

@objc
public class RemoteTrackPublication: TrackPublication {

    public var subscriptionAllowed: Bool { _state.subscriptionAllowed }
    public var enabled: Bool { _state.trackSettings.enabled }
    override public var muted: Bool { track?.muted ?? _state.metadataMuted }

    // MARK: - Private

    // adaptiveStream
    // this must be on .main queue
    private var asTimer = DispatchQueueTimer(timeInterval: 0.3, queue: .main)

    internal override init(info: Livekit_TrackInfo,
                           track: Track? = nil,
                           participant: Participant) {

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

    public override var subscribed: Bool {
        if !subscriptionAllowed { return false }
        return _state.preferSubscribed != false && super.subscribed
    }

    public var subscriptionState: SubscriptionState {
        if !subscriptionAllowed { return .notAllowed }
        return self.subscribed ? .subscribed : .unsubscribed
    }

    /// Subscribe or unsubscribe from this track.
    public func set(subscribed newValue: Bool) async throws {

        guard _state.preferSubscribed != newValue else { return }

        let participant = try await requireParticipant()

        _state.mutate { $0.preferSubscribed = newValue }

        try await participant.room.engine.signalClient.sendUpdateSubscription(participantSid: participant.sid,
                                                                              trackSid: sid,
                                                                              subscribed: newValue)
    }

    /// Enable or disable server from sending down data for this track.
    ///
    /// This is useful when the participant is off screen, you may disable streaming down their video to reduce bandwidth requirements.
    public func set(enabled newValue: Bool) async throws {
        // No-op if already the desired value
        let trackSettings = _state.trackSettings
        guard trackSettings.enabled != newValue else { return }

        try await userCanModifyTrackSettings()

        let settings = trackSettings.copyWith(enabled: newValue)
        // Attempt to set the new settings
        try await send(trackSettings: settings)
    }

    /// Set preferred video FPS for this track.
    public func set(preferredFPS newValue: UInt) async throws {
        // No-op if already the desired value
        let trackSettings = _state.trackSettings
        guard trackSettings.preferredFPS != newValue else { return }

        try await userCanModifyTrackSettings()

        let settings = trackSettings.copyWith(preferredFPS: newValue)
        // Attempt to set the new settings
        try await send(trackSettings: settings)
    }

    @discardableResult
    internal override func set(track newValue: Track?) -> Track? {

        log("RemoteTrackPublication set track: \(String(describing: newValue))")

        let oldValue = super.set(track: newValue)
        if newValue != oldValue {
            // always suspend adaptiveStream timer first
            asTimer.suspend()

            if let newValue = newValue {

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
                newValue.set(muted: _state.metadataMuted,
                             notify: false)
            }

            if let oldValue = oldValue, newValue == nil, let participant = participant as? RemoteParticipant {
                participant.delegates.notify(label: { "participant.didUnsubscribe \(self)" }) {
                    $0.participant?(participant, didUnsubscribe: self, track: oldValue)
                }
                participant.room.delegates.notify(label: { "room.didUnsubscribe \(self)" }) {
                    $0.room?(participant.room, participant: participant, didUnsubscribe: self, track: oldValue)
                }
            }
        }

        return oldValue
    }
}

// MARK: - Private

private extension RemoteTrackPublication {

    var isAdaptiveStreamEnabled: Bool { (participant?.room._state.options ?? RoomOptions()).adaptiveStream && .video == kind }

    var engineConnectionState: ConnectionState {

        guard let participant = participant else {
            log("Participant is nil", .warning)
            return .disconnected()
        }

        return participant.room.engine._state.connectionState
    }

    func userCanModifyTrackSettings() async throws {
        // adaptiveStream must be disabled and must be subscribed
        if isAdaptiveStreamEnabled || !subscribed {
            throw TrackError.state(message: "adaptiveStream must be disabled and track must be subscribed")
        }
    }
}

// MARK: - Internal

internal extension RemoteTrackPublication {

    func set(metadataMuted newValue: Bool) {

        guard _state.metadataMuted != newValue else { return }

        guard let participant = participant else {
            log("Participant is nil", .warning)
            return
        }

        _state.mutate { $0.metadataMuted = newValue }

        // if track exists, track will emit the following events
        if track == nil {
            participant.delegates.notify(label: { "participant.didUpdate muted: \(newValue)" }) {
                $0.participant?(participant, didUpdate: self, muted: newValue)
            }
            participant.room.delegates.notify(label: { "room.didUpdate muted: \(newValue)" }) {
                $0.room?(participant.room, participant: participant, didUpdate: self, muted: newValue)
            }
        }
    }

    func set(subscriptionAllowed newValue: Bool) {
        guard _state.subscriptionAllowed != newValue else { return }
        _state.mutate { $0.subscriptionAllowed = newValue }

        guard let participant = self.participant as? RemoteParticipant else { return }
        participant.delegates.notify(label: { "participant.didUpdate permission: \(newValue)" }) {
            $0.participant?(participant, didUpdate: self, permission: newValue)
        }
        participant.room.delegates.notify(label: { "room.didUpdate permission: \(newValue)" }) {
            $0.room?(participant.room, participant: participant, didUpdate: self, permission: newValue)
        }
    }
}

// MARK: - TrackSettings

internal extension RemoteTrackPublication {

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
            throw EngineError.state(message: "Already busy sending new track settings")
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
        } catch let error {
            // Revert track settings on failure
            _state.mutate {
                $0.trackSettings = state.trackSettings
                $0.isSendingTrackSettings = false
            }

            log("Failed to send track settings: \(newValue), sid: \(self.sid), error: \(error)")
        }
    }
}

// MARK: - Adaptive Stream

internal extension Collection where Element == VideoRenderer {

    func containsOneOrMoreAdaptiveStreamEnabledRenderers() -> Bool {
        // not visible if no entry
        if isEmpty { return false }
        // at least 1 entry should be visible
        return contains { $0.adaptiveStreamIsEnabled }
    }

    func largestSize() -> CGSize? {

        func maxCGSize(_ s1: CGSize, _ s2: CGSize) -> CGSize {
            CGSize(width: Swift.max(s1.width, s2.width),
                   height: Swift.max(s1.height, s2.height))
        }

        // use post-layout nativeRenderer's view size otherwise return nil
        // which results lower layer to be requested (enabled: true, dimensions: 0x0)
        return filter { $0.adaptiveStreamIsEnabled }
            .compactMap { $0.adaptiveStreamSize != .zero ? $0.adaptiveStreamSize : nil }
            .reduce(into: nil as CGSize?, { previous, current in
                guard let unwrappedPrevious = previous else {
                    previous = current
                    return
                }
                previous = maxCGSize(unwrappedPrevious, current)
            })
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
        guard !engineConnectionState.isDisconnected else {
            log("engine is disconnected")
            return
        }

        let videoRenderers = track?.videoRenderers.allObjects ?? []
        let enabled = videoRenderers.containsOneOrMoreAdaptiveStreamEnabledRenderers()
        var dimensions: Dimensions = .zero

        // compute the largest video view size
        if enabled, let maxSize = videoRenderers.largestSize() {
            dimensions = Dimensions(width: Int32(ceil(maxSize.width)),
                                    height: Int32(ceil(maxSize.height)))
        }

        let newSettings = _state.trackSettings.copyWith(enabled: enabled, dimensions: dimensions)

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
        if oldSettings.enabled, !newSettings.enabled {
            let viewsString = videoRenderers.enumerated().map { (i, v) in "videoRenderer\(i)(adaptiveStreamIsEnabled: \(v.adaptiveStreamIsEnabled), adaptiveStreamSize: \(v.adaptiveStreamSize))" }.joined(separator: ", ")
            log("[adaptiveStream] disabling sid: \(sid), videoRenderersCount: \(videoRenderers.count), \(viewsString)")
        }

        if let videoTrack = track?.mediaTrack as? LKRTCVideoTrack {
            log("VideoTrack.shouldReceive: \(enabled)")
            DispatchQueue.liveKitWebRTC.sync { videoTrack.shouldReceive = enabled }
        }

        Task {
            do {
                try await send(trackSettings: newSettings)
            } catch let error {
                // Revert to old settings on failure
                _state.mutate { $0.trackSettings = oldSettings }
                log("[adaptiveStream] failed to send trackSettings, sid: \(self.sid) error: \(error)", .error)
            }

            asTimer.restart()
        }
    }
}
