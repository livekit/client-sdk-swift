//
//  File.swift
//
//
//  Created by Russell D'Sa on 12/15/20.
//

import Foundation

public class TrackPublication {
    public internal(set) var track: Track?
    public internal(set) var name: String
    public private(set) var sid: String
    public private(set) var kind: Track.Kind
    public internal(set) var muted: Bool

    weak var participant: Participant?

    public var subscribed: Bool { return track != nil }

    init(info: Livekit_TrackInfo, track: Track? = nil, participant: Participant? = nil) {
        sid = info.sid
        name = info.name
        kind = Track.fromProtoKind(info.type)
        muted = info.muted
        self.track = track
        self.participant = participant
    }

    func updateFromInfo(info: Livekit_TrackInfo) {
        // only muted and name can conceivably update
        name = info.name
        muted = info.muted
    }
}
