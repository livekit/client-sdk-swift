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

internal import LiveKitWebRTC
import Foundation

extension Room {
    func engine(_: Room, didMutateState state: Room.State, oldState: Room.State) {
        if state.connectionState != oldState.connectionState {
            // connectionState did update

            // only if quick-reconnect
            if case .connected = state.connectionState, case .quick = state.isReconnectingWithMode {
                resetTrackSettings()
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
                    delegates.notify { $0.room?(self, didFailToConnectWithError: state.disconnectError) }
                } else {
                    delegates.notify { $0.room?(self, didDisconnectWithError: state.disconnectError) }
                }
            }
        }

        // Notify when reconnection starts
        if oldState.isReconnectingWithMode == nil, state.isReconnectingWithMode != nil, let startMode = state.isReconnectingWithMode {
            delegates.notify(label: { "room.didStartReconnectWithMode: \(startMode)" }) {
                $0.room?(self, didStartReconnectWithMode: startMode)
            }
        }

        // Notify when reconnection completes
        if oldState.isReconnectingWithMode != nil, state.isReconnectingWithMode == nil, let completedMode = oldState.isReconnectingWithMode {
            delegates.notify(label: { "room.didCompleteReconnectWithMode: \(completedMode)" }) {
                $0.room?(self, didCompleteReconnectWithMode: completedMode)
            }
        }

        // Notify when reconnection mode changes
        if state.isReconnectingWithMode != oldState.isReconnectingWithMode,
           let mode = state.isReconnectingWithMode
        {
            delegates.notify(label: { "room.didUpdate reconnectionMode: \(String(describing: state.isReconnectingWithMode)) oldValue: \(String(describing: oldState.isReconnectingWithMode))" }) {
                $0.room?(self, didUpdateReconnectMode: mode)
            }
        }

        // Notify change when engine's state mutates
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }

    func engine(_ engine: Room, didUpdateSpeakers speakers: [Livekit_SpeakerInfo]) {
        let activeSpeakers = _state.mutate { state -> [Participant] in
            var activeSpeakers: [Participant] = []
            var seenParticipantSids = [Participant.Sid: Bool]()
            for speaker in speakers {
                let participantSid = Participant.Sid(from: speaker.sid)
                seenParticipantSids[participantSid] = true
                if participantSid == localParticipant.sid {
                    localParticipant._state.mutate {
                        $0.audioLevel = speaker.level
                        if !$0.isSpeaking {
                            $0.lastSpokeAt = Date()
                        }
                        $0.isSpeaking = true
                    }
                    activeSpeakers.append(localParticipant)
                } else if let participant = state.remoteParticipant(forSid: participantSid) {
                    participant._state.mutate {
                        $0.audioLevel = speaker.level
                        if !$0.isSpeaking {
                            $0.lastSpokeAt = Date()
                        }
                        $0.isSpeaking = true
                    }
                    activeSpeakers.append(participant)
                }
            }

            if let localParticipantSid = localParticipant.sid, seenParticipantSids[localParticipantSid] == nil {
                localParticipant._state.mutate {
                    $0.audioLevel = 0.0
                    $0.isSpeaking = false
                }
            }

            for participant in state.remoteParticipants.values {
                if let participantSid = participant.sid, seenParticipantSids[participantSid] == nil {
                    participant._state.mutate {
                        $0.audioLevel = 0.0
                        $0.isSpeaking = false
                    }
                }
            }

            state.activeSpeakers = activeSpeakers
            return activeSpeakers
        }

        if case .connected = engine._state.connectionState {
            delegates.notify(label: { "room.didUpdate speakers: \(activeSpeakers)" }) {
                $0.room?(self, didUpdateSpeakingParticipants: activeSpeakers)
            }
        }
    }

    func engine(_: Room, didAddTrack track: RTCMediaTrack, rtpReceiver: RTCReceiver, streamId: String) async {
        let parseResult = parse(streamId: streamId)
        let trackId = parseResult.trackId ?? Track.Sid(from: track.trackId)

        let participant = _state.read {
            $0.remoteParticipants.values.first { $0.sid == parseResult.participantSid }
        }

        guard let participant else {
            log("RemoteParticipant not found for sid: \(parseResult.participantSid), remoteParticipants: \(remoteParticipants)", .warning)
            return
        }

        let task = Task.retrying(retryDelay: 0.2) { _, _ in
            // TODO: Only retry for TrackError.state = error
            try await participant.addSubscribedMediaTrack(mediaTrack: track, rtpReceiver: rtpReceiver, trackSid: trackId)
        }

        do {
            try await task.value
        } catch {
            log("addSubscribedMediaTrack failed, error: \(error)", .error)
        }
    }

    func engine(_: Room, didRemoveTrackWithId trackId: String) async {
        // Find the publication
        let trackSid = Track.Sid(from: trackId)
        guard let publication = _state.remoteParticipants.values.map(\._state.trackPublications.values).joined()
            .first(where: { $0.sid == trackSid }) else { return }
        await publication.set(track: nil)
    }

    func engine(_ engine: Room, didReceiveUserPacket packet: Livekit_UserPacket, participantIdentity: String, encryptionType: EncryptionType) {
        // participant could be null if data broadcasted from server
        let participant = _state.remoteParticipants[Participant.Identity(from: participantIdentity)]

        if case .connected = engine._state.connectionState {
            delegates.notify(label: { "room.didReceive data: \(packet.payload)" }) {
                $0.room?(self, participant: participant, didReceiveData: packet.payload, forTopic: packet.topic, encryptionType: encryptionType)
            }

            if let participant {
                participant.delegates.notify(label: { "participant.didReceive data: \(packet.payload)" }) { [weak participant] delegate in
                    guard let participant else { return }
                    delegate.participant?(participant, didReceiveData: packet.payload, forTopic: packet.topic, encryptionType: encryptionType)
                }
            }
        }
    }

    func room(didReceiveTranscriptionPacket packet: Livekit_Transcription) {
        // Try to find matching Participant.
        guard let participant = allParticipants[Participant.Identity(from: packet.transcribedParticipantIdentity)] else {
            log("[Transcription] Could not find participant: \(packet.transcribedParticipantIdentity)", .warning)
            return
        }

        guard let publication = participant._state.read({ $0.trackPublications[Track.Sid(from: packet.trackID)] }) else {
            log("[Transcription] Could not find publication: \(packet.trackID)", .warning)
            return
        }

        guard !packet.segments.isEmpty else {
            log("[Transcription] Received segments are empty", .warning)
            return
        }

        let segments = packet.segments.map { segment in
            TranscriptionSegment(id: segment.id,
                                 text: segment.text,
                                 language: segment.language,
                                 firstReceivedTime: _state.transcriptionReceivedTimes[segment.id] ?? Date(),
                                 lastReceivedTime: Date(),
                                 isFinal: segment.final)
        }

        _state.mutate { state in
            for segment in segments {
                if segment.isFinal {
                    state.transcriptionReceivedTimes.removeValue(forKey: segment.id)
                } else {
                    state.transcriptionReceivedTimes[segment.id] = segment.firstReceivedTime
                }
            }
        }

        delegates.notify {
            $0.room?(self, participant: participant, trackPublication: publication, didReceiveTranscriptionSegments: segments)
        }

        participant.delegates.notify {
            $0.participant?(participant, trackPublication: publication, didReceiveTranscriptionSegments: segments)
        }
    }
}
