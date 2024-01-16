/*
 * Copyright 2024 LiveKit
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

@_implementationOnly import WebRTC

extension Room: EngineDelegate {
    func engine(_: Engine, didMutateState state: Engine.State, oldState: Engine.State) {
        if state.connectionState != oldState.connectionState {
            // connectionState did update

            // only if quick-reconnect
            if case .connected = state.connectionState, case .quick = state.reconnectMode {
                resetTrackSettings()
            }

            // Re-send track permissions
            if case .connected = state.connectionState {
                Task {
                    do {
                        try await localParticipant.sendTrackSubscriptionPermissions()
                    } catch {
                        log("Failed to send track subscription permissions, error: \(error)", .error)
                    }
                }
            }

            delegates.notify(label: { "room.didUpdate connectionState: \(state.connectionState) oldValue: \(oldState.connectionState)" }) {
                $0.room?(self, didUpdateConnectionState: state.connectionState, from: oldState.connectionState)
            }

            // Individual connectionState delegates
            if case .connected = state.connectionState {
                // Connected
                if case .reconnecting = oldState.connectionState {
                    delegates.notify { $0.roomDidReconnect?(self) }
                } else {
                    delegates.notify { $0.roomDidConnect?(self) }
                }
            } else if case .reconnecting = state.connectionState {
                // Re-connecting
                delegates.notify { $0.roomIsReconnecting?(self) }
            } else if case .disconnected = state.connectionState {
                // Disconnected
                if case .connecting = oldState.connectionState {
                    delegates.notify { $0.room?(self, didFailToConnectWithError: oldState.disconnectError) }
                } else {
                    delegates.notify { $0.room?(self, didDisconnectWithError: state.disconnectError) }
                }
            }
        }

        if state.connectionState == .reconnecting, state.reconnectMode == .full, oldState.reconnectMode != .full {
            Task {
                // Started full reconnect
                await cleanUpParticipants(notify: true)
            }
        }

        // Notify change when engine's state mutates
        Task.detached { @MainActor in
            self.objectWillChange.send()
        }
    }

    func engine(_ engine: Engine, didUpdateSpeakers speakers: [Livekit_SpeakerInfo]) {
        let activeSpeakers = _state.mutate { state -> [Participant] in

            var activeSpeakers: [Participant] = []
            var seenSids = [String: Bool]()
            for speaker in speakers {
                seenSids[speaker.sid] = true
                if speaker.sid == localParticipant.sid {
                    localParticipant._state.mutate {
                        $0.audioLevel = speaker.level
                        $0.isSpeaking = true
                    }
                    activeSpeakers.append(localParticipant)
                } else {
                    if let participant = state.remoteParticipant(sid: speaker.sid) {
                        participant._state.mutate {
                            $0.audioLevel = speaker.level
                            $0.isSpeaking = true
                        }
                        activeSpeakers.append(participant)
                    }
                }
            }

            if seenSids[localParticipant.sid] == nil {
                localParticipant._state.mutate {
                    $0.audioLevel = 0.0
                    $0.isSpeaking = false
                }
            }

            for participant in state.remoteParticipants.values {
                if seenSids[participant.sid] == nil {
                    participant._state.mutate {
                        $0.audioLevel = 0.0
                        $0.isSpeaking = false
                    }
                }
            }

            return activeSpeakers
        }

        engine.executeIfConnected { [weak self] in
            guard let self else { return }

            self.delegates.notify(label: { "room.didUpdate speakers: \(activeSpeakers)" }) {
                $0.room?(self, didUpdateSpeakingParticipants: activeSpeakers)
            }
        }
    }

    func engine(_: Engine, didAddTrack track: LKRTCMediaStreamTrack, rtpReceiver: LKRTCRtpReceiver, stream: LKRTCMediaStream) {
        let parts = stream.streamId.unpack()
        let trackId = !parts.trackId.isEmpty ? parts.trackId : track.trackId

        let participant = _state.read {
            $0.remoteParticipants.values.first { $0.sid == parts.participantSid }
        }

        guard let participant else {
            log("RemoteParticipant not found for sid: \(parts.participantSid), remoteParticipants: \(remoteParticipants)", .warning)
            return
        }

        let task = Task.retrying(retryDelay: 0.2) { _, _ in
            // TODO: Only retry for TrackError.state = error
            try await participant.addSubscribedMediaTrack(rtcTrack: track, rtpReceiver: rtpReceiver, sid: trackId)
        }

        Task {
            try await task.value
        }
    }

    func engine(_: Engine, didRemoveTrack track: LKRTCMediaStreamTrack) {
        // find the publication
        guard let publication = _state.remoteParticipants.values.map(\._state.trackPublications.values).joined()
            .first(where: { $0.sid == track.trackId }) else { return }
        publication.set(track: nil)
    }

    func engine(_ engine: Engine, didReceiveUserPacket packet: Livekit_UserPacket) {
        // participant could be null if data broadcasted from server
        let participant = _state.remoteParticipants[packet.participantIdentity]

        engine.executeIfConnected { [weak self] in
            guard let self else { return }

            self.delegates.notify(label: { "room.didReceive data: \(packet.payload)" }) {
                $0.room?(self, participant: participant, didReceiveData: packet.payload, forTopic: packet.topic)
            }

            if let participant {
                participant.delegates.notify(label: { "participant.didReceive data: \(packet.payload)" }) { [weak participant] delegate in
                    guard let participant else { return }
                    delegate.participant?(participant, didReceiveData: packet.payload, forTopic: packet.topic)
                }
            }
        }
    }
}
