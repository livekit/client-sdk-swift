import Foundation
import CoreGraphics
import Promises

public class RemoteTrackPublication: TrackPublication {
    // have we explicitly unsubscribed
    var unsubscribed: Bool = false
    public internal(set) var enabled: Bool = true

    private var metadataMuted: Bool = false

    #if LK_FEATURE_ADAPTIVESTREAM
    private var videoViewVisibilities = [Int: VideoViewVisibility]()
    private weak var pendingDebounceFunc: DispatchWorkItem?
    private var debouncedRecomputeVideoViewVisibilities: DebouncFunc?
    private var lastSentVideoTrackSettings: VideoTrackSettings?
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
                  participant: Participant? = nil) {

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

    /// subscribe or unsubscribe from this track
    public func setSubscribed(_ subscribed: Bool) {
        unsubscribed = !subscribed
        guard let participant = participant else { return }

        participant.room.engine.signalClient.sendUpdateSubscription(
            participantSid: participant.sid,
            trackSid: sid,
            subscribed: !unsubscribed
        ).catch { error in
            self.log("Failed to set subscribed, error: \(error)", .error)
        }
    }

    /// disable server from sending down data for this track
    ///
    /// this is useful when the participant is off screen, you may disable streaming down their video to reduce bandwidth requirements
    @available(*, deprecated, message: "Use enable() or disable() instead.")
    public func setEnabled(_ enabled: Bool) {
        let promise = enabled ? enable() : disable()
        promise.catch { error in
            self.log("Failed to set enabled, error: \(error)", .error)
        }
    }

    public func enable() -> Promise<Void> {

        guard !enabled else {
            // already enabled
            return Promise(())
        }

        guard let participant = participant else {
            return Promise(EngineError.state(message: "Participant is nil"))
        }

        return participant.room.engine.signalClient.sendUpdateTrackSettings(sid: sid, enabled: true).then {
            self.enabled = true
        }
    }

    public func disable() -> Promise<Void> {

        guard enabled else {
            // already disabled
            return Promise(())
        }

        guard let participant = participant else {
            return Promise(EngineError.state(message: "Participant is nil"))
        }

        return participant.room.engine.signalClient.sendUpdateTrackSettings(sid: sid, enabled: false).then {
            self.enabled = false
        }
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

// MARK: - Video Optimizations

extension RemoteTrackPublication {

    private func hasVisibleVideoViews() -> Bool {
        // not visible if no entry
        if videoViewVisibilities.isEmpty { return false }
        // at least 1 entry should be visible
        return videoViewVisibilities.values.first(where: { $0.visible }) != nil
    }

    private func shouldComputeVideoViewVisibilities() {

        let roomOptions = participant?.room.roomOptions ?? RoomOptions()
        guard roomOptions.adaptiveStream else {
            // adaptiveStream is turned off
            return
        }

        // decide whether to debounce or immediately compute video view visibilities
        if let settings = lastSentVideoTrackSettings,
           settings.enabled == false,
           hasVisibleVideoViews() {
            // immediately compute (quick enable)
            log("Attempting quick enable (no deboucne)")
            pendingDebounceFunc?.cancel()
            recomputeVideoViewVisibilities()
        } else {
            debouncedRecomputeVideoViewVisibilities?()
        }
    }

    private func recomputeVideoViewVisibilities() {

        func send(_ settings: VideoTrackSettings) -> Promise<Void> {

            guard let client = participant?.room.engine.signalClient else {
                return Promise(EngineError.state(message: "Participant is nil"))
            }

            log("sendUpdateTrackSettings enabled: \(settings.enabled), viewSize: \(settings.size)")
            return client.sendUpdateTrackSettings(sid: sid,
                                                  enabled: settings.enabled,
                                                  width: Int(ceil(settings.size.width)),
                                                  height: Int(ceil(settings.size.height)))
        }

        // set internal enabled var
        enabled = hasVisibleVideoViews()
        var size: CGSize = .zero

        // compute the largest video view size
        if enabled, let maxSize = videoViewVisibilities.values.largestVideoViewSize() {
            size = maxSize
        }

        let videoSettings = VideoTrackSettings(enabled: enabled, size: size)
        // only send if different from previously sent settings
        if videoSettings != lastSentVideoTrackSettings {
            lastSentVideoTrackSettings = videoSettings
            send(videoSettings).catch { error in
                self.log("Failed to send track settings, error: \(error)", .error)
            }
        }
    }
}
#endif

public enum SubscriptionStatus {
    case subscribed
    case notAllowed
    case unsubscribed
}

// MARK: - Video Optimization related structs
#if LK_FEATURE_ADAPTIVESTREAM
struct VideoViewVisibility {
    let visible: Bool
    let size: CGSize
}
#endif

struct VideoTrackSettings {
    let enabled: Bool
    let size: CGSize
}

// MARK: - Video Optimization related extensions

extension VideoTrackSettings: Equatable {

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.enabled == rhs.enabled &&
            lhs.size == rhs.size
    }
}

#if LK_FEATURE_ADAPTIVESTREAM

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
