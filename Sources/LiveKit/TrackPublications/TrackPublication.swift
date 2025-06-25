/*
 * Copyright 2025 LiveKit
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

@objc
public class TrackPublication: NSObject, @unchecked Sendable, ObservableObject, Loggable {
    // MARK: - Public properties

    @objc
    public var sid: Track.Sid { _state.sid }

    @objc
    public var kind: Track.Kind { _state.kind }

    @objc
    public var source: Track.Source { _state.source }

    @objc
    public var name: String { _state.name }

    @objc
    public var track: Track? { _state.track }

    @objc
    public var isMuted: Bool { track?._state.isMuted ?? false }

    @objc
    public var streamState: StreamState { _state.streamState }

    /// video-only
    @objc
    public var dimensions: Dimensions? { _state.dimensions }

    @objc
    public var isSimulcasted: Bool { _state.isSimulcasted }

    /// MIME type of the ``Track``.
    @objc
    public var mimeType: String { _state.mimeType }

    @objc
    public var isSubscribed: Bool { _state.track != nil }

    @objc
    public var encryptionType: EncryptionType { _state.encryptionType }

    // MARK: - Internal

    let queue = DispatchQueue(label: "LiveKitSDK.publication", qos: .default)

    /// Reference to the ``Participant`` this publication belongs to.
    weak var participant: Participant?

    struct State: Equatable, Hashable {
        let sid: Track.Sid
        let kind: Track.Kind
        let source: Track.Source

        var track: Track?
        var name: String
        var mimeType: String
        var isSimulcasted: Bool = false
        var dimensions: Dimensions?
        // subscription permission
        var isSubscriptionAllowed = true
        //
        var streamState: StreamState = .paused
        var trackSettings = TrackSettings()
        //
        var isSendingTrackSettings: Bool = false

        // Only for RemoteTrackPublications
        // user's preference to subscribe or not
        var isSubscribePreferred: Bool?
        var isMetadataMuted: Bool = false
        var encryptionType: EncryptionType = .none

        var latestInfo: Livekit_TrackInfo?

        var audioTrackFeatures: Set<Livekit_AudioTrackFeature>?
    }

    let _state: StateSync<State>

    init(info: Livekit_TrackInfo, participant: Participant) {
        _state = StateSync(State(
            sid: Track.Sid(from: info.sid),
            kind: info.type.toLKType(),
            source: info.source.toLKType(),
            name: info.name,
            mimeType: info.mimeType,
            isSimulcasted: info.simulcast,
            dimensions: info.type == .video ? Dimensions(width: Int32(info.width), height: Int32(info.height)) : nil,
            isMetadataMuted: info.muted,
            encryptionType: info.encryption.toLKType(),
            latestInfo: info,
            audioTrackFeatures: Set(info.audioFeatures)
        ))

        self.participant = participant

        super.init()

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in
            guard let self else { return }

            if newState.streamState != oldState.streamState {
                if let participant = self.participant as? RemoteParticipant,
                   let room = participant._room,
                   let trackPublication = self as? RemoteTrackPublication
                {
                    participant.delegates.notify(label: { "participant.didUpdate \(trackPublication) streamState: \(newState.streamState)" }) {
                        $0.participant?(participant, trackPublication: trackPublication, didUpdateStreamState: newState.streamState)
                    }
                    room.delegates.notify(label: { "room.didUpdate \(trackPublication) streamState: \(newState.streamState)" }) {
                        $0.room?(room, participant: participant, trackPublication: trackPublication, didUpdateStreamState: newState.streamState)
                    }
                }
            }

            notifyObjectWillChange()
        }
    }

    func notifyObjectWillChange() {
        // Notify UI that the object has changed
        Task { @MainActor in
            // Notify TrackPublication
            self.objectWillChange.send()

            if let participant = self.participant {
                // Notify Participant
                participant.objectWillChange.send()

                if let room = participant._room {
                    // Notify Room
                    room.objectWillChange.send()
                }
            }
        }
    }

    func updateFromInfo(info: Livekit_TrackInfo) {
        _state.mutate {
            // only muted and name can conceivably update
            $0.name = info.name
            $0.isSimulcasted = info.simulcast
            $0.mimeType = info.mimeType
            $0.dimensions = info.type == .video ? Dimensions(width: Int32(info.width), height: Int32(info.height)) : nil

            // store the whole info
            $0.latestInfo = info
        }
    }

    @discardableResult
    func set(track newValue: Track?) async -> Track? {
        // keep ref to old value
        let oldValue = track
        // continue only if updated
        guard track != newValue else { return oldValue }
        log("\(String(describing: oldValue)) -> \(String(describing: newValue))")

        // listen for visibility updates
        track?.remove(delegate: self)
        newValue?.add(delegate: self)

        _state.mutate { $0.track = newValue }

        return oldValue
    }
}

// MARK: - TrackDelegate

extension TrackPublication: TrackDelegateInternal {
    func track(_ track: Track, didMutateState newState: Track.State, oldState: Track.State) {
        // Notify on UI updating changes
        if newState.isMuted != oldState.isMuted {
            log("Track didMutateState newState: \(newState), oldState: \(oldState), kind: \(track.kind)")
            notifyObjectWillChange()
        }
    }

    public func track(_: Track, didUpdateIsMuted isMuted: Bool, shouldSendSignal: Bool) {
        log("isMuted: \(isMuted) shouldSendSignal: \(shouldSendSignal)")

        Task.detached {
            let participant = try await self.requireParticipant()
            let room = try participant.requireRoom()

            if shouldSendSignal {
                try await room.signalClient.sendMuteTrack(trackSid: self.sid, muted: isMuted)
            }

            participant.delegates.notify {
                $0.participant?(participant, trackPublication: self, didUpdateIsMuted: isMuted)
            }
            room.delegates.notify {
                $0.room?(room, participant: participant, trackPublication: self, didUpdateIsMuted: self.isMuted)
            }

            // TrackPublication.isMuted is a computed property depending on Track.isMuted
            // so emit event on TrackPublication when Track.isMuted updates
            Task { @MainActor in
                self.objectWillChange.send()
            }
        }
    }
}

// MARK: - Internal helpers

extension TrackPublication {
    func requireParticipant() async throws -> Participant {
        guard let participant else {
            log("Participant is nil", .error)
            throw LiveKitError(.invalidState, message: "Participant is nil")
        }

        return participant
    }
}
