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
    internal weak var participant: Participant?

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

    public func track(_ track: VideoTrack, videoView: VideoView, didLayout size: CGSize) {
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

        guard let participant = participant else {
            log("Participant is nil", .warning)
            return
        }

        func sendSignal() -> Promise<Void> {

            guard shouldSendSignal else {
                return Promise(())
            }

            return participant.room.engine.signalClient.sendMuteTrack(trackSid: sid,
                                                                      muted: muted)
        }

        sendSignal()
            .recover(on: .sdk) { self.log("Failed to stop all tracks, error: \($0)") }
            .then(on: .sdk) {
                participant.notify { $0.participant(participant, didUpdate: self, muted: muted) }
                participant.room.notify { $0.room(participant.room, participant: participant, didUpdate: self, muted: self.muted) }
            }
    }
}
