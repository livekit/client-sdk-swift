import Foundation
import CoreGraphics

extension TrackPublication: Equatable {
    // objects are considered equal if sids are the same
    public static func == (lhs: TrackPublication, rhs: TrackPublication) -> Bool {
        lhs.sid == rhs.sid
    }
}

public class TrackPublication: TrackDelegate, Loggable {

    public let sid: Sid
    public let kind: Track.Kind
    public let source: Track.Source
    public internal(set) var name: String
    public internal(set) var track: Track? {
        didSet {
            guard oldValue != track else { return }

            // listen for visibility updates
            oldValue?.remove(delegate: self)
            track?.add(delegate: self)
        }
    }

    public var muted: Bool {
        track?.muted ?? false
    }

    /// video-only
    public internal(set) var dimensions: Dimensions?

    /// video-only
    public internal(set) var simulcasted: Bool = false

    /// MIME type of the ``Track``.
    public internal(set) var mimeType: String

    /// Reference to the ``Participant`` this publication belongs to.
    internal weak var participant: Participant?

    public var subscribed: Bool { return track != nil }

    internal init(info: Livekit_TrackInfo,
                  track: Track? = nil,
                  participant: Participant? = nil) {

        self.sid = info.sid
        self.name = info.name
        self.kind = info.type.toLKType()
        self.source = info.source.toLKType()
        self.mimeType = info.mimeType
        self.track = track
        self.participant = participant
        updateFromInfo(info: info)

        // listen for events from Track
        track?.add(delegate: self)
    }

    internal func updateFromInfo(info: Livekit_TrackInfo) {
        // only muted and name can conceivably update
        self.name = info.name
        self.simulcasted = info.simulcast
        self.mimeType = info.mimeType
        if info.type == .video {
            dimensions = Dimensions(width: Int32(info.width),
                                    height: Int32(info.height))
        }
    }

    // MARK: - TrackDelegate

    public func track(_ track: VideoTrack, videoView: VideoView, didUpdate size: CGSize) {
        //
    }

    public func track(_ track: VideoTrack, didAttach videoView: VideoView) {
        //
    }

    public func track(_ track: VideoTrack, didDetach videoView: VideoView) {
        //
    }

    public func track(_ track: Track, didUpdate muted: Bool, shouldSendSignal: Bool) {
        //
        log("track didUpdate muted: \(muted) shouldSendSignal: \(shouldSendSignal)")

        guard let participant = participant else {
            log("Participant is nil", .warning)
            return
        }

        if shouldSendSignal {
            participant.room.engine.signalClient.sendMuteTrack(trackSid: sid, muted: muted)
        }

        participant.notify { $0.participant(participant, didUpdate: self, muted: muted) }
        participant.room.notify { $0.room(participant.room, participant: participant, didUpdate: self, muted: self.muted) }
    }

    public func track(_ track: Track, capturer: VideoCapturer, didUpdate dimensions: Dimensions?) {
        //
        log("Track capturer didUpdate dimensions: \(String(describing: dimensions))")
    }
}
