import Foundation
import CoreGraphics
import Promises

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
    public private(set) var track: Track?

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
    internal let participant: Participant

    public var subscribed: Bool { return track != nil }

    internal private(set) var latestInfo: Livekit_TrackInfo?

    internal init(info: Livekit_TrackInfo,
                  track: Track? = nil,
                  participant: Participant) {

        self.sid = info.sid
        self.name = info.name
        self.kind = info.type.toLKType()
        self.source = info.source.toLKType()
        self.mimeType = info.mimeType
        self.participant = participant
        self.set(track: track)
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
        self.latestInfo = info
    }

    @discardableResult
    internal func set(track newValue: Track?) -> Track? {
        // keep ref to old value
        let oldValue = self.track
        // continue only if updated
        guard self.track != newValue else { return oldValue }
        log("\(String(describing: oldValue)) -> \(String(describing: newValue))")

        // listen for visibility updates
        self.track?.remove(delegate: self)
        newValue?.add(delegate: self)

        self.track = newValue
        return oldValue
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
        log("muted: \(muted) shouldSendSignal: \(shouldSendSignal)")

        func sendSignal() -> Promise<Void> {

            guard shouldSendSignal else {
                return Promise(())
            }

            return participant.room.engine.signalClient.sendMuteTrack(trackSid: sid,
                                                                      muted: muted)
        }

        sendSignal().always {
            self.participant.notify { $0.participant(self.participant, didUpdate: self, muted: muted) }
            self.participant.room.notify { $0.room(self.participant.room, participant: self.participant, didUpdate: self, muted: self.muted) }
        }
    }
}
