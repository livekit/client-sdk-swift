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

public class TrackPublication: TrackDelegate, Loggable {

    internal let queue = DispatchQueue(label: "LiveKitSDK.publication", qos: .default)

    public let sid: Sid
    public let kind: Track.Kind
    public let source: Track.Source

    public var name: String { _state.name }
    public var track: Track? { _state.track }
    public var muted: Bool { track?._state.muted ?? false }
    public var streamState: StreamState { _state.streamState }

    /// video-only
    public var dimensions: Dimensions? { _state.dimensions }
    public var simulcasted: Bool { _state.simulcasted }
    /// MIME type of the ``Track``.
    public var mimeType: String { _state.mimeType }
    public var subscribed: Bool { _state.track != nil }

    // MARK: - Internal

    /// Reference to the ``Participant`` this publication belongs to.
    internal weak var participant: Participant?
    internal private(set) var latestInfo: Livekit_TrackInfo?

    internal struct State {
        var track: Track?
        var name: String
        var mimeType: String
        var simulcasted: Bool = false
        var dimensions: Dimensions?
        // subscription permission
        var subscriptionAllowed = true
        //
        var streamState: StreamState = .paused
        var trackSettings = TrackSettings()
    }

    internal var _state: StateSync<State>

    internal init(info: Livekit_TrackInfo,
                  track: Track? = nil,
                  participant: Participant) {

        // initial state
        _state = StateSync(State(
            name: info.name,
            mimeType: info.mimeType
        ))

        self.sid = info.sid
        self.kind = info.type.toLKType()
        self.source = info.source.toLKType()
        self.participant = participant
        self.set(track: track)
        updateFromInfo(info: info)

        // listen for events from Track
        track?.add(delegate: self)

        // trigger events when state mutates
        self._state.onMutate = { [weak self] state, oldState in

            guard let self = self else { return }

            if state.streamState != oldState.streamState {
                if let participant = self.participant as? RemoteParticipant, let trackPublication = self as? RemoteTrackPublication {
                    participant.notify(label: { "participant.didUpdate \(trackPublication) streamState: \(state.streamState)" }) {
                        $0.participant(participant, didUpdate: trackPublication, streamState: state.streamState)
                    }
                    participant.room.notify(label: { "room.didUpdate \(trackPublication) streamState: \(state.streamState)" }) {
                        $0.room(participant.room, participant: participant, didUpdate: trackPublication, streamState: state.streamState)
                    }
                }
            }
        }
    }

    deinit {
        log("sid: \(sid)")
    }

    internal func updateFromInfo(info: Livekit_TrackInfo) {

        _state.mutate {

            // only muted and name can conceivably update
            $0.name = info.name
            $0.simulcasted = info.simulcast
            $0.mimeType = info.mimeType

            // only for video
            if info.type == .video {
                $0.dimensions = Dimensions(width: Int32(info.width),
                                           height: Int32(info.height))
            }
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

        _state.mutate { $0.track = newValue }

        return oldValue
    }

    // MARK: - TrackDelegate

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
            .recover(on: queue) { self.log("Failed to stop all tracks, error: \($0)") }
            .then(on: queue) {
                participant.notify {
                    $0.participant(participant, didUpdate: self, muted: muted)
                }
                participant.room.notify {
                    $0.room(participant.room, participant: participant, didUpdate: self, muted: self.muted)
                }
            }
    }
}

// MARK: - Equatable

extension TrackPublication: Equatable {
    // objects are considered equal if sids are the same
    public static func == (lhs: TrackPublication, rhs: TrackPublication) -> Bool {
        lhs.sid == rhs.sid
    }
}
