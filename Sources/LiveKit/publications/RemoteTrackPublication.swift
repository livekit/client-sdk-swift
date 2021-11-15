import Foundation
import CoreGraphics

struct VideoViewVisibility {
    let visible: Bool
    let size: CGSize
}

struct VideoTrackSettings {
    let enabled: Bool
    let size: CGSize
}

extension VideoTrackSettings: Equatable {
    
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.enabled == rhs.enabled &&
        lhs.size == rhs.size
    }
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

public class RemoteTrackPublication: TrackPublication {
    // have we explicitly unsubscribed
    var unsubscribed: Bool = false
    var enabled: Bool = true

    private var videoViewVisibilities = [Int: VideoViewVisibility]()
    private weak var pendingDebounceFunc: DispatchWorkItem?
    private var shouldRecomputeVisibilities: DebouncFunc?
    private var lastSentVideoTrackSettings: VideoTrackSettings?

    public override var track: Track? {
        didSet {
            guard oldValue != track else { return }

            // cancel the pending debounce func
            pendingDebounceFunc?.cancel()
            videoViewVisibilities.removeAll()

            // listen for visibility updates
            oldValue?.remove(delegate: self)
            track?.add(delegate: self)
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

        shouldRecomputeVisibilities = Utils.createDebounceFunc(wait: 2,
                                                               onCreateWorkItem: { [weak self] in
                                                                self?.pendingDebounceFunc = $0
                                                               }) { [weak self] in
            self?.recomputeVideoViewVisibilities()
        }

        // initial trigger
        shouldRecomputeVisibilities?()
    }

    deinit {
        // cancel the pending debounce func
        pendingDebounceFunc?.cancel()
    }

    override public internal(set) var muted: Bool {
        didSet {
            if muted == oldValue {
                return
            }
            guard let participant = self.participant else {
                return
            }
            //            if muted {
            participant.notify { $0.participant(participant, didUpdate: self, muted: self.muted) }
            participant.room?.notify { $0.room(participant.room!, participant: participant, didUpdate: self, muted: self.muted) }
            //            } else {
            //                participant.notify { $0.participant(participant, didUpdate: self.muted, trackPublication: self) }
            //                participant.room?.notify { $0.didUnmute(publication: self, participant: participant) }
            //            }
        }
    }

    override public var subscribed: Bool {
        if unsubscribed {
            return false
        }
        // unless explicitly unsubscribed, defer to parent logic
        return super.subscribed
    }

    /// subscribe or unsubscribe from this track
    public func setSubscribed(_ subscribed: Bool) {
        unsubscribed = !subscribed
        guard let client = participant?.room?.engine.signalClient else {
            return
        }

        client.sendUpdateSubscription(sid: sid,
                                      subscribed: !unsubscribed)
    }

    /// disable server from sending down data for this track
    ///
    /// this is useful when the participant is off screen, you may disable streaming down their video to reduce bandwidth requirements
    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        guard let client = participant?.room?.engine.signalClient else { return }
        client.sendUpdateTrackSettings(sid: sid,
                                       enabled: enabled)
    }
}

// MARK: - Video Optimizations

extension RemoteTrackPublication: TrackDelegate {

    public func track(_ track: VideoTrack,
                      videoView: VideoView,
                      didUpdate size: CGSize) {

        videoViewVisibilities[videoView.hash] = VideoViewVisibility(visible: true,
                                                                    size: size)
        shouldRecomputeVisibilities?()
    }

    public func track(_ track: VideoTrack,
                      didAttach videoView: VideoView) {
        
        videoViewVisibilities[videoView.hash] = VideoViewVisibility(visible: true,
                                                                    size: videoView.viewSize)
        shouldRecomputeVisibilities?()
    }

    public func track(_ track: VideoTrack,
                      didDetach videoView: VideoView) {

        videoViewVisibilities.removeValue(forKey: videoView.hash)
        shouldRecomputeVisibilities?()
    }

    private func hasVisibleVideoViews() -> Bool {
        // not visible if no entry
        if videoViewVisibilities.isEmpty { return false }
        // at least 1 entry should be visible
        return videoViewVisibilities.values.first(where: { $0.visible }) != nil
    }

    private func recomputeVideoViewVisibilities() {
        
        func send(_ settings: VideoTrackSettings) {
            guard let client = participant?.room?.engine.signalClient else { return }
            print("sendUpdateTrackSettings enabled: \(settings.enabled), viewSize: \(settings.size)")
            client.sendUpdateTrackSettings(sid: sid,
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
            send(videoSettings)
        }
    }
}
