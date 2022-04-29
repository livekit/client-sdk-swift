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

    public private(set) var subscriptionAllowed = true

    public var enabled: Bool {
        trackSettings.enabled
    }

    override public var muted: Bool {
        track?.muted ?? metadataMuted
    }

    public var streamState: StreamState { _state.streamState }

    // user's preference to subscribe or not
    private var preferSubscribed: Bool?

    private var metadataMuted: Bool = false

    private var trackSettings = TrackSettings() {
        didSet {
            guard oldValue != trackSettings else { return }
            log("did update trackSettings: \(trackSettings)")
            // TODO: emit event when trackSettings has been updated by adaptiveStream.
        }
    }

    // adaptiveStream
    // this must be on .main queue
    private var asTimer = DispatchQueueTimer(timeInterval: 0.3, queue: .main)

    override init(info: Livekit_TrackInfo,
                  track: Track? = nil,
                  participant: Participant) {

        super.init(info: info,
                   track: track,
                   participant: participant)

        asTimer.handler = { [weak self] in self?.onAdaptiveStreamTimer() }
    }

    deinit {
        log()
        asTimer.suspend()
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
        ).then(on: .sdk) {
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
        return checkCanModifyTrackSettings().then(on: .sdk) {
            self.send(trackSettings: newSettings)
        }
    }

    @discardableResult
    internal override func set(track newValue: Track?) -> Track? {
        let oldValue = super.set(track: newValue)
        if newValue != oldValue {
            // always suspend adaptiveStream timer first
            asTimer.suspend()

            if let newValue = newValue {

                let adaptiveStreamEnabled = (participant?.room.options ?? RoomOptions()).adaptiveStream && .video == newValue.kind

                // reset track settings
                // track is initially disabled only if adaptive stream and is a video track
                trackSettings = TrackSettings(enabled: !adaptiveStreamEnabled)

                log("did reset trackSettings: \(trackSettings), kind: \(newValue.kind)")

                // start adaptiveStream timer only if it's a video track
                if adaptiveStreamEnabled {
                    asTimer.restart()
                }

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

    internal func engineConnectionState() -> ConnectionState {

        guard let participant = participant else {
            log("Participant is nil", .warning)
            return .disconnected()
        }

        return participant.room.engine._state.connection
    }
}

// MARK: - Adaptive Stream

internal extension Collection where Element == VideoView {

    func hasVisible() -> Bool {
        // not visible if no entry
        if isEmpty { return false }
        // at least 1 entry should be visible
        return contains { $0.isVisible }
    }

    func largestSize() -> CGSize? {

        func maxCGSize(_ s1: CGSize, _ s2: CGSize) -> CGSize {
            CGSize(width: Swift.max(s1.width, s2.width),
                   height: Swift.max(s1.height, s2.height))
        }

        return filter { $0.isVisible }.compactMap { $0._state.rendererSize }.reduce(into: nil as CGSize?, { previous, current in
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
        guard !engineConnectionState().isDisconnected else {
            log("engine is disconnected")
            return
        }

        let asViews = track?.videoViews.allObjects ?? []

        if asViews.count > 1 {
            log("multiple VideoViews attached, count: \(asViews.count), trackId: \(track?.sid ?? "") views: (\(asViews.map { "\($0.hashValue)" }.joined(separator: ", ")))", .warning)
        }

        let enabled = asViews.hasVisible()
        var dimensions: Dimensions = .zero

        // compute the largest video view size
        if enabled, let maxSize = asViews.largestSize() {
            dimensions = Dimensions(width: Int32(ceil(maxSize.width)),
                                    height: Int32(ceil(maxSize.height)))
        }

        let newSettings = trackSettings.copyWith(enabled: enabled,
                                                 dimensions: dimensions)

        guard self.trackSettings != newSettings else {
            // no settings updated
            asTimer.resume()
            return
        }

        send(trackSettings: newSettings).catch(on: .main) { [weak self] error in
            self?.log("Failed to send trackSettings, error: \(error)", .error)
        }.always(on: .main) { [weak self] in
            self?.asTimer.restart()
        }
    }
}
