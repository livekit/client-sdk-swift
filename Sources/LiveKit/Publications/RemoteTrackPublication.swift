import Foundation
import CoreGraphics
import Promises

public enum SubscriptionStatus {
    case subscribed
    case notAllowed
    case unsubscribed
}

public class RemoteTrackPublication: TrackPublication {
    // have we explicitly unsubscribed
    var unsubscribed: Bool = false

    public var enabled: Bool {
        trackSettings.enabled
    }

    private var metadataMuted: Bool = false

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

    public internal(set) var subscriptionAllowed = true {
        didSet {
            guard oldValue != subscriptionAllowed else { return }
            guard let participant = self.participant as? RemoteParticipant else { return }
            participant.notify { $0.participant(participant, didUpdate: self, permission: self.subscriptionAllowed) }
            participant.room.notify { $0.room(participant.room, participant: participant, didUpdate: self, permission: self.subscriptionAllowed) }

            if subscriptionAllowed && subscriptionState == .subscribed {
                guard let track = self.track else { return }
                participant.notify { $0.participant(participant, didSubscribe: self, track: track) }
                participant.room.notify { $0.room(participant.room, participant: participant, didSubscribe: self, track: track) }
            } else if !subscriptionAllowed && subscriptionState == .notAllowed {
                guard let track = self.track else { return }
                participant.notify { $0.participant(participant, didUnsubscribe: self, track: track) }
                participant.room.notify { $0.room(participant.room, participant: participant, didUnsubscribe: self)}
            }
        }
    }
    override public internal(set) var track: Track? {
        didSet {
            guard oldValue != track else { return }

            #if LK_FEATURE_ADAPTIVESTREAM
            // cancel the pending debounce func
            pendingDebounceFunc?.cancel()
            videoViewVisibilities.removeAll()
            #endif
            // if new Track has been set to this RemoteTrackPublication,
            // update the Track's muted state from the latest info.
            track?.update(muted: metadataMuted,
                          shouldNotify: false)
        }
    }

    override init(info: Livekit_TrackInfo,
                  track: Track? = nil,
                  participant: Participant) {

        super.init(info: info,
                   track: track,
                   participant: participant)

        // listen for visibility updates
        track?.add(delegate: self)

        #if LK_FEATURE_ADAPTIVESTREAM
        debouncedRecomputeVideoViewVisibilities = Utils.createDebounceFunc(wait: 2,
                                                                           onCreateWorkItem: { [weak self] in
                                                                            self?.pendingDebounceFunc = $0
                                                                           }) { [weak self] in
            self?.recomputeVideoViewVisibilities()
        }

        // initial trigger
        shouldComputeVideoViewVisibilities()
        #endif
    }

    deinit {
        #if LK_FEATURE_ADAPTIVESTREAM
        // cancel the pending debounce func
        pendingDebounceFunc?.cancel()
        #endif
    }

    override func updateFromInfo(info: Livekit_TrackInfo) {
        super.updateFromInfo(info: info)
        track?.update(muted: info.muted)
        metadataMuted = info.muted
    }

    override public var subscribed: Bool {
        if unsubscribed || !subscriptionAllowed {
            return false
        }
        // unless explicitly unsubscribed, defer to parent logic
        return super.subscribed
    }

    public var subscriptionState: SubscriptionStatus {
        if unsubscribed || !super.subscribed {
            return .unsubscribed
        } else if !subscriptionAllowed {
            return .notAllowed
        } else {
            return .subscribed
        }
    }

    /// Subscribe or unsubscribe from this track.
    @discardableResult
    public func set(subscribed: Bool) -> Promise<Void> {
        unsubscribed = !subscribed

        return participant.room.engine.signalClient.sendUpdateSubscription(
            participantSid: participant.sid,
            trackSid: sid,
            subscribed: !unsubscribed
        )
    }

    /// Enable or disable server from sending down data for this track.
    ///
    /// This is useful when the participant is off screen, you may disable streaming down their video to reduce bandwidth requirements.
    @discardableResult
    public func set(enabled: Bool) -> Promise<Void> {
        guard self.enabled != enabled else { return Promise(()) }
        return send(trackSettings: trackSettings.copyWith(enabled: enabled))
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

        guard participant.room.options.adaptiveStream else {
            // adaptiveStream is turned off
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
        participant.room.engine.signalClient.sendUpdateTrackSettings(sid: sid, settings: self.trackSettings)
    }

    // Send new track settings
    internal func send(trackSettings: TrackSettings) -> Promise<Void> {
        // no-update
        guard self.trackSettings != trackSettings else { return Promise(()) }

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
