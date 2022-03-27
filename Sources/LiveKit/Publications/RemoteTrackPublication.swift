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

    public internal(set) var streamState: StreamState = .paused {
        didSet {
            guard oldValue != streamState else { return }
            guard let participant = self.participant as? RemoteParticipant else { return }
            participant.notify { $0.participant(participant, didUpdate: self, streamState: self.streamState) }
            participant.room.notify { $0.room(participant.room, participant: participant, didUpdate: self, streamState: self.streamState) }
        }
    }

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
    private var asViews = Set<AdaptiveStreamEntry>()
    // this must be on .main queue
    private var asTimer = DispatchQueueTimer(timeInterval: 0.5, queue: .main)

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
            // always suspend adaptiveStream timer first
            asTimer.suspend()
            asViews.removeAll()

            if let newValue = newValue {

                // start adaptiveStream timer only if it's a video track
                if (participant?.room.options.adaptiveStream ?? false), newValue.kind == .video {
                    asTimer.resume()
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

    // MARK: - TrackDelegate

    public override func track(_ track: VideoTrack, didAttach videoView: VideoView) {
        log()
        // create a new entry
        asViews.insert(AdaptiveStreamEntry(videoView: videoView))
    }

    public override func track(_ track: VideoTrack, didDetach videoView: VideoView) {
        log()

        //
        while let releasedEntry = asViews.first(where: { $0.videoViewHashValue == videoView.hashValue }) {
            log("removing entry...")
            asViews.remove(releasedEntry)
        }

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
}

// MARK: - Adaptive Stream

internal extension Collection where Element == AdaptiveStreamEntry {

    func hasVisible() -> Bool {
        // not visible if no entry
        if isEmpty { return false }
        // at least 1 entry should be visible
        return first(where: { $0.isVisible }) != nil
    }

    func largestSize() -> CGSize? {

        func maxCGSize(_ s1: CGSize, _ s2: CGSize) -> CGSize {
            CGSize(width: Swift.max(s1.width, s2.width),
                   height: Swift.max(s1.height, s2.height))
        }

        return filter { $0.isVisible }.compactMap { $0.videoSize }.reduce(into: nil as CGSize?, { previous, current in
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

        // suspend timer first
        asTimer.suspend()

        // clean up entries for released video views
        while let releasedEntry = asViews.first(where: { $0.isReleased }) {
            log("adaptiveStream: cleaning up entry (\(releasedEntry.videoViewHashValue)...")
            asViews.remove(releasedEntry)
        }

        log("asViews: \(asViews.count)")
        //        guard asViews.first(where: { $0.videoView?.didLayout ?? false }) != nil else {
        //            // not a single VideoView has completed layout yet,
        //            // there is no point con
        //            log("all views have not completed layout")
        //            asTimer.resume()
        //            return
        //        }

        let enabled = asViews.hasVisible()
        var dimensions: Dimensions = .zero

        // compute the largest video view size
        if enabled, let maxSize = asViews.largestSize() {
            dimensions = Dimensions(width: Int32(ceil(maxSize.width)),
                                    height: Int32(ceil(maxSize.height)))
        }

        let newSettings = trackSettings.copyWith(enabled: enabled,
                                                 dimensions: dimensions)

        // requests can be sent on .sdk queue
        send(trackSettings: newSettings).catch(on: .sdk) { [weak self] error in
            self?.log("Failed to send track settings, error: \(error)", .error)
        }.always(on: .sdk) { [weak self] in
            self?.asTimer.resume()
        }
    }
}

// MARK: - AdaptiveStreamEntry

class AdaptiveStreamEntry {

    // hash of the VideoView
    let videoViewHashValue: Int

    // weak ref to VideoView
    // clean up logic will remove this entry
    weak var videoView: VideoView?

    // weak ref was released
    var isReleased: Bool {
        videoView == nil
    }

    // whether it should be enabled or not
    var isVisible: Bool {
        guard let videoView = videoView else { return false }
        return !videoView.isHidden && videoView.isEnabled
    }

    //
    var videoSize: CGSize? {
        // rendererSize reflects the layoutMode(.fit/.fill)
        videoView?.rendererSize
    }

    init(videoView: VideoView) {
        self.videoViewHashValue = videoView.hashValue
        self.videoView = videoView
    }
}

// conform to Hashable so it can be unique in Sets
extension AdaptiveStreamEntry: Hashable {

    static func == (lhs: AdaptiveStreamEntry, rhs: AdaptiveStreamEntry) -> Bool {
        lhs.videoViewHashValue == rhs.videoViewHashValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(videoViewHashValue)
    }
}
