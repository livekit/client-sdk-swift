import Foundation
import CoreGraphics

struct VideoViewVisibility {
    let visible: Bool
    let size: CGSize
}

public class RemoteTrackPublication: TrackPublication {
    // have we explicitly unsubscribed
    var unsubscribed: Bool = false
    var enabled: Bool = true

    private var videoViewVisibilities = [Int: VideoViewVisibility]()
    private weak var pendingDebounceFunc: DispatchWorkItem?
    private var shouldRecomputeVisibilities: DebouncFunc?

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
                                       disabled: enabled)
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

    private func largestVideoViewSize() -> CGSize? {

        func maxCGSize(_ s1: CGSize, _ s2: CGSize) -> CGSize {
            CGSize(width: max(s1.width, s2.width),
                   height: max(s1.height, s2.height))
        }

        return videoViewVisibilities.values.map({ $0.size }).reduce(into: nil as CGSize?, { result, element in
            guard let unwrappedResult = result else {
                result = element
                return
            }
            result = maxCGSize(unwrappedResult, element)
        })
    }

    private func recomputeVideoViewVisibilities() {

        // set internal enabled var
        self.enabled = hasVisibleVideoViews()

        var width: Int = 0,
            height: Int = 0

        if enabled, let maxSize = largestVideoViewSize() {
            print("Max size is \(maxSize)")
            width = Int(ceil(maxSize.width))
            height = Int(ceil(maxSize.height))
        }

        guard let client = participant?.room?.engine.signalClient else { return }
        client.sendUpdateTrackSettings(sid: sid,
                                       disabled: !enabled,
                                       width: width,
                                       height: height)

        print("sendUpdateTrackSettings enabled: \(enabled), dimensions: \(width)x\(height)")
    }
}
