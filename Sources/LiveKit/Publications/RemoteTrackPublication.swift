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
import Promises

public enum SubscriptionState {
    case subscribed
    case notAllowed
    case unsubscribed
}

public class RemoteTrackPublication: TrackPublication {
    // user's preference to subscribe or not
    private var preferSubscribed: Bool?

    public private(set) var subscriptionAllowed = true

    public var enabled: Bool {
        trackSettings.enabled
    }

    private var metadataMuted: Bool = false

    override public var muted: Bool {
        track?.muted ?? metadataMuted
    }

    private var trackSettings = TrackSettings() {
        didSet {
            guard oldValue != trackSettings else { return }
            log("did update trackSettings: \(trackSettings)")
            // TODO: emit event when trackSettings has been updated by adaptiveStream.
        }
    }

    #if LK_FEATURE_ADAPTIVESTREAM
    private var videoViewVisibilities = [Int: VideoViewVisibility]()
    private weak var pendingDebounceFunc: DispatchWorkItem?
    private var debouncedRecomputeVideoViewVisibilities: DebouncFunc?
    #endif

    public internal(set) var streamState: StreamState = .paused {
        didSet {
            guard oldValue != streamState else { return }
            guard let participant = self.participant as? RemoteParticipant else { return }
            participant.notify { $0.participant(participant, didUpdate: self, streamState: self.streamState) }
            participant.room.notify { $0.room(participant.room, participant: participant, didUpdate: self, streamState: self.streamState) }
        }
    }

    override init(info: Livekit_TrackInfo,
                  track: Track? = nil,
                  participant: Participant) {

        super.init(info: info,
                   track: track,
                   participant: participant)
    }

    deinit {
        #if LK_FEATURE_ADAPTIVESTREAM
        // cancel the pending debounce func
        pendingDebounceFunc?.cancel()
        #endif
    }

    override func updateFromInfo(info: Livekit_TrackInfo) {
        super.updateFromInfo(info: info)
        track?.set(muted: info.muted)
        set(metadataMuted: info.muted)
    }

    override public var subscribed: Bool {
        if !subscriptionAllowed { return false }
        return preferSubscribed != false && super.subscribed
    }

    public var subscriptionState: SubscriptionState {
        if !subscriptionAllowed { return .notAllowed }
        return self.subscribed ? .subscribed : .unsubscribed
    }

    /// Subscribe or unsubscribe from this track.
    @discardableResult
    public func set(subscribed newValue: Bool) -> Promise<Void> {

        guard self.preferSubscribed != newValue else { return Promise(()) }

        guard let participant = participant else {
            log("Participant is nil", .warning)
            return Promise(EngineError.state(message: "Participant is nil"))
        }

        return participant.room.engine.signalClient.sendUpdateSubscription(
            participantSid: participant.sid,
            trackSid: sid,
            subscribed: newValue
        ).then {
            self.preferSubscribed = newValue
        }
    }

    /// Enable or disable server from sending down data for this track.
    ///
    /// This is useful when the participant is off screen, you may disable streaming down their video to reduce bandwidth requirements.
    @discardableResult
    public func set(enabled: Bool) -> Promise<Void> {
        // no-op if already the desired value
        guard self.enabled != enabled else { return Promise(()) }
        // create new settings
        let newSettings = trackSettings.copyWith(enabled: enabled)
        // attempt to set the new settings
        return checkCanModifyTrackSettings().then {
            self.send(trackSettings: newSettings)
        }
    }

    @discardableResult
    internal override func set(track newValue: Track?) -> Track? {
        let oldValue = super.set(track: newValue)
        if newValue != oldValue {
            #if LK_FEATURE_ADAPTIVESTREAM
            // always cancel the pending debounce func
            pendingDebounceFunc?.cancel()
            videoViewVisibilities.removeAll()
            #endif

            if let newValue = newValue {

                #if LK_FEATURE_ADAPTIVESTREAM
                // only if is video track
                if newValue.kind == .video {

                    if debouncedRecomputeVideoViewVisibilities == nil {
                        // create debounce func
                        debouncedRecomputeVideoViewVisibilities = Utils.createDebounceFunc(wait: 2,
                                                                                           onCreateWorkItem: { [weak self] in
                                                                                            self?.pendingDebounceFunc = $0
                                                                                           }, fnc: { [weak self] in
                                                                                            self?.recomputeVideoViewVisibilities()
                                                                                           })

                    }

                    // initial trigger
                    shouldComputeVideoViewVisibilities()
                }
                #endif

                // if new Track has been set to this RemoteTrackPublication,
                // update the Track's muted state from the latest info.
                newValue.set(muted: metadataMuted,
                             shouldNotify: false)
            }

            if let oldValue = oldValue, newValue == nil,
               let participant = participant as? RemoteParticipant {
                participant.notify { $0.participant(participant, didUnsubscribe: self, track: oldValue) }
                participant.room.notify { $0.room(participant.room, participant: participant, didUnsubscribe: self, track: oldValue) }
            }
        }
        return oldValue
    }

    #if LK_FEATURE_ADAPTIVESTREAM

    // MARK: - TrackDelegate

    override public func track(_ track: VideoTrack,
                               videoView: VideoView,
                               didUpdate size: CGSize) {

        videoViewVisibilities[videoView.hash] = VideoViewVisibility(visible: true,
                                                                    size: size)
        shouldComputeVideoViewVisibilities()
    }

    override public func track(_ track: VideoTrack,
                               didAttach videoView: VideoView) {

        videoViewVisibilities[videoView.hash] = VideoViewVisibility(visible: true,
                                                                    size: videoView.viewSize)
        shouldComputeVideoViewVisibilities()
    }

    override public func track(_ track: VideoTrack,
                               didDetach videoView: VideoView) {

        videoViewVisibilities.removeValue(forKey: videoView.hash)
        shouldComputeVideoViewVisibilities()
    }
    #endif
}

// MARK: - Private

private extension RemoteTrackPublication {

    func checkCanModifyTrackSettings() -> Promise<Void> {

        Promise<Void>(on: .sdk) { () -> Void in

            guard let adaptiveStream = self.participant?.room.options.adaptiveStream else {
                throw TrackError.state(message: "The state of AdaptiveStream is unknown")
            }

            guard !adaptiveStream else {
                throw TrackError.state(message: "Cannot modify this track setting when using AdaptiveStream")
            }

            guard self.subscribed else {
                throw TrackError.state(message: "Cannot modify this track setting when not subscribed")
            }
        }
    }
}

// MARK: - Internal

internal extension RemoteTrackPublication {

    func set(metadataMuted newValue: Bool) {

        guard self.metadataMuted != newValue else { return }

        guard let participant = participant else {
            log("Participant is nil", .warning)
            return
        }

        self.metadataMuted = newValue
        // if track exists, track will emit the following events
        if track == nil {
            participant.notify { $0.participant(participant, didUpdate: self, muted: newValue) }
            participant.room.notify { $0.room(participant.room, participant: participant, didUpdate: self, muted: newValue) }
        }
    }

    func set(subscriptionAllowed newValue: Bool) {
        guard self.subscriptionAllowed != newValue else { return }
        self.subscriptionAllowed = newValue

        guard let participant = self.participant as? RemoteParticipant else { return }
        participant.notify { $0.participant(participant, didUpdate: self, permission: newValue) }
        participant.room.notify { $0.room(participant.room, participant: participant, didUpdate: self, permission: newValue) }
    }
}

#if LK_FEATURE_ADAPTIVESTREAM

// MARK: - Adaptive Stream

extension RemoteTrackPublication {

    private func hasVisibleVideoViews() -> Bool {
        // not visible if no entry
        if videoViewVisibilities.isEmpty { return false }
        // at least 1 entry should be visible
        return videoViewVisibilities.values.first(where: { $0.visible }) != nil
    }

    private func shouldComputeVideoViewVisibilities() {
        log()

        guard let participant = participant else {
            log("Participant is nil", .warning)
            return
        }

        guard participant.room.options.adaptiveStream else {
            // adaptiveStream is turned off
            return
        }

        guard let track = track, track.kind == .video else {
            log("Track is not a video track", .warning)
            return
        }

        // decide whether to debounce or immediately compute video view visibilities
        if trackSettings.enabled == false, hasVisibleVideoViews() {
            // immediately compute (quick enable)
            log("Attempting quick enable (no deboucne)")
            pendingDebounceFunc?.cancel()
            recomputeVideoViewVisibilities()
        } else {
            debouncedRecomputeVideoViewVisibilities?()
        }
    }

    private func recomputeVideoViewVisibilities() {
        log()

        guard let track = track, track.kind == .video else {
            log("Track is not a video track", .warning)
            return
        }

        // set internal enabled var
        let enabled = hasVisibleVideoViews()
        var dimensions: Dimensions = .zero

        // compute the largest video view size
        if enabled, let maxSize = videoViewVisibilities.values.largestVideoViewSize() {
            dimensions = Dimensions(width: Int32(ceil(maxSize.width)),
                                    height: Int32(ceil(maxSize.height)))
        }

        let newSettings = TrackSettings(enabled: enabled,
                                        dimensions: dimensions)

        send(trackSettings: newSettings).catch { error in
            self.log("Failed to send track settings, error: \(error)", .error)
        }
    }
}
#endif

// MARK: - TrackSettings

extension RemoteTrackPublication {

    // Simply send current track settings without any checks
    internal func sendCurrentTrackSettings() -> Promise<Void> {

        guard let participant = participant else {
            log("Participant is nil", .warning)
            return Promise(EngineError.state(message: "Participant is nil"))
        }

        return participant.room.engine.signalClient.sendUpdateTrackSettings(sid: sid, settings: self.trackSettings)
    }

    // Send new track settings
    internal func send(trackSettings: TrackSettings) -> Promise<Void> {
        // no-update
        guard self.trackSettings != trackSettings else { return Promise(()) }

        guard let participant = participant else {
            log("Participant is nil", .warning)
            return Promise(EngineError.state(message: "Participant is nil"))
        }

        return participant.room.engine.signalClient.sendUpdateTrackSettings(sid: sid, settings: trackSettings).then(on: .sdk) {
            self.trackSettings = trackSettings
        }
    }
}

// MARK: - Adaptive Stream

#if LK_FEATURE_ADAPTIVESTREAM

struct VideoViewVisibility {
    let visible: Bool
    let size: CGSize
}

extension Sequence where Element == VideoViewVisibility {

    func largestVideoViewSize() -> CGSize? {

        func maxCGSize(_ s1: CGSize, _ s2: CGSize) -> CGSize {
            CGSize(width: Swift.max(s1.width, s2.width),
                   height: Swift.max(s1.height, s2.height))
        }

        return map({ $0.size }).reduce(into: nil as CGSize?, { previous, current in
            guard let unwrappedPrevious = previous else {
                previous = current
                return
            }
            previous = maxCGSize(unwrappedPrevious, current)
        })
    }
}

#endif
