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
import Combine

@objc
public class TrackPublication: NSObject, ObservableObject, Loggable {

    // MARK: - Public properties

    @objc
    public var sid: Sid { _state.sid }

    @objc
    public var kind: Track.Kind { _state.kind }

    @objc
    public var source: Track.Source { _state.source }

    @objc
    public var name: String { _state.name }

    @objc
    public var track: Track? { _state.track }

    @objc
    public var muted: Bool { track?._state.muted ?? false }

    @objc
    public var streamState: StreamState { _state.streamState }

    /// video-only
    @objc
    public var dimensions: Dimensions? { _state.dimensions }

    @objc
    public var simulcasted: Bool { _state.simulcasted }

    /// MIME type of the ``Track``.
    @objc
    public var mimeType: String { _state.mimeType }

    @objc
    public var subscribed: Bool { _state.track != nil }

    @objc
    public var encryptionType: EncryptionType { _state.encryptionType }

    // MARK: - Internal

    internal let queue = DispatchQueue(label: "LiveKitSDK.publication", qos: .default)

    /// Reference to the ``Participant`` this publication belongs to.
    internal weak var participant: Participant?

    internal struct State: Equatable, Hashable {
        let sid: Sid
        let kind: Track.Kind
        let source: Track.Source

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
        //
        var isSendingTrackSettings: Bool = false

        // Only for RemoteTrackPublications
        // user's preference to subscribe or not
        var preferSubscribed: Bool?
        var metadataMuted: Bool = false
        var encryptionType: EncryptionType = .none

        var latestInfo: Livekit_TrackInfo?
    }

    internal var _state: StateSync<State>

    internal init(info: Livekit_TrackInfo,
                  track: Track? = nil,
                  participant: Participant) {

        _state = StateSync(State(
            sid: info.sid,
            kind: info.type.toLKType(),
            source: info.source.toLKType(),
            name: info.name,
            mimeType: info.mimeType,
            simulcasted: info.simulcast,
            dimensions: info.type == .video ? Dimensions(width: Int32(info.width), height: Int32(info.height)) : nil,
            metadataMuted: info.muted,
            encryptionType: info.encryption.toLKType(),

            // store the whole info
            latestInfo: info
        ))

        self.participant = participant

        super.init()

        self.set(track: track)

        // listen for events from Track
        track?.add(delegate: self)

        // trigger events when state mutates
        self._state.onDidMutate = { [weak self] newState, oldState in

            guard let self = self else { return }

            if newState.streamState != oldState.streamState {
                if let participant = self.participant as? RemoteParticipant, let trackPublication = self as? RemoteTrackPublication {
                    participant.delegates.notify(label: { "participant.didUpdate \(trackPublication) streamState: \(newState.streamState)" }) {
                        $0.participant?(participant, didUpdate: trackPublication, streamState: newState.streamState)
                    }
                    participant.room.delegates.notify(label: { "room.didUpdate \(trackPublication) streamState: \(newState.streamState)" }) {
                        $0.room?(participant.room, participant: participant, didUpdate: trackPublication, streamState: newState.streamState)
                    }
                }
            }

            self.notifyObjectWillChange()
        }
    }

    deinit {
        log("sid: \(sid)")
    }

    internal func notifyObjectWillChange() {
        // Notify UI that the object has changed
        Task.detached { @MainActor in
            // Notify TrackPublication
            self.objectWillChange.send()

            if let participant = self.participant {
                // Notify Participant
                participant.objectWillChange.send()
                // Notify Room
                participant.room.objectWillChange.send()
            }
        }
    }

    internal func updateFromInfo(info: Livekit_TrackInfo) {

        _state.mutate {
            // only muted and name can conceivably update
            $0.name = info.name
            $0.simulcasted = info.simulcast
            $0.mimeType = info.mimeType
            $0.dimensions = info.type == .video ? Dimensions(width: Int32(info.width), height: Int32(info.height)) : nil

            // store the whole info
            $0.latestInfo = info
        }
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
}

// MARK: - TrackDelegate

extension TrackPublication: TrackDelegateInternal {

    func track(_ track: Track, didMutateState newState: Track.State, oldState: Track.State) {
        // Notify on UI updating changes
        if newState.muted != oldState.muted {
            log("Track didMutateState newState: \(newState), oldState: \(oldState), kind: \(track.kind)")
            notifyObjectWillChange()
        }
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
            .recover(on: queue) { self.log("Failed to stop all tracks, error: \($0)") }
            .then(on: queue) {
                participant.delegates.notify {
                    $0.participant?(participant, didUpdate: self, muted: muted)
                }
                participant.room.delegates.notify {
                    $0.room?(participant.room, participant: participant, didUpdate: self, muted: self.muted)
                }
                // TrackPublication.muted is a computed property depending on Track.muted
                // so emit event on TrackPublication when Track.muted updates
                Task.detached { @MainActor in
                    self.objectWillChange.send()
                }
            }
    }
}
