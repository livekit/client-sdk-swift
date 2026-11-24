/*
 * Copyright 2026 LiveKit
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

extension Room {
    func engine(_: Room, didMutateState state: Room.State, oldState: Room.State) {
        if state.connectionState != oldState.connectionState {
            // connectionState did update

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
                    delegates.notify { $0.room?(self, didFailToConnectWithError: state.disconnectError) }
                } else {
                    delegates.notify { $0.room?(self, didDisconnectWithError: state.disconnectError) }
                }
            }
        }

        // Notify change when engine's state mutates
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }

    func didUpdateSpeakers(_ speakers: [(participant: Participant, level: Float)]) {
        let participants: [Participant] = [localParticipant] + Array(_state.remoteParticipants.values)
        for participant in participants {
            let level = speakers.first { $0.participant === participant }?.level
            participant._state.mutate {
                if level != nil, !$0.isSpeaking { $0.lastSpokeAt = Date() }
                $0.audioLevel = level ?? 0
                $0.isSpeaking = level != nil
            }
        }
        let activeSpeakers = speakers.map(\.participant)
        _state.mutate { $0.activeSpeakers = activeSpeakers }

        if case .connected = _state.connectionState {
            delegates.notify(label: { "room.didUpdate speakers: \(activeSpeakers)" }) {
                $0.room?(self, didUpdateSpeakingParticipants: activeSpeakers)
            }
        }
    }

    // Native packets omit encryption metadata, so the legacy callback reports `.none`.
    func didReceive(data: Data, topic: String, participantIdentity: String) {
        // participant could be null if data broadcasted from server
        let participant = _state.remoteParticipants[Participant.Identity(from: participantIdentity)]

        guard case .connected = _state.connectionState else { return }
        delegates.notify(label: { "room.didReceive data: \(data)" }) {
            $0.room?(self, participant: participant, didReceiveData: data, forTopic: topic, encryptionType: .none)
        }

        if let participant {
            participant.delegates.notify(label: { "participant.didReceive data: \(data)" }) { [weak participant] delegate in
                guard let participant else { return }
                delegate.participant?(participant, didReceiveData: data, forTopic: topic, encryptionType: .none)
            }
        }
    }
}
