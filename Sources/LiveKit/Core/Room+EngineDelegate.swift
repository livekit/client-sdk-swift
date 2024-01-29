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

extension Room {
    func onDidUpdateSpeakers(speakers: [Livekit_SpeakerInfo]) async {
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

        // Proceed only if connected...
        if case .connected = _state.connectionState {
            _delegates.notify(label: { "room.didUpdate speakers: \(activeSpeakers)" }) {
                $0.room?(self, didUpdateSpeakingParticipants: activeSpeakers)
            }
        }
    }

    func onDidAddTrack(track: LKRTCMediaStreamTrack, rtpReceiver: LKRTCRtpReceiver, stream: LKRTCMediaStream) async {
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

        do {
            try await task.value
        } catch {
            log("addSubscribedMediaTrack failed, error: \(error)", .error)
        }
    }

    func onDidRemoveTrack(track: LKRTCMediaStreamTrack) async {
        // find the publication
        guard let publication = _state.remoteParticipants.values.map(\._state.trackPublications.values).joined()
            .first(where: { $0.sid == track.trackId }) else { return }
        await publication.set(track: nil)
    }

    func onDidReceiveUserPacket(packet: Livekit_UserPacket) async {
        // participant could be null if data broadcasted from server
        let participant = _state.remoteParticipants[packet.participantIdentity]

        // Proceed only if connected...
        if case .connected = _state.connectionState {
            _delegates.notify(label: { "room.didReceive data: \(packet.payload)" }) {
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
