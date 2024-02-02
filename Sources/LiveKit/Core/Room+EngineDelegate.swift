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
            var seenParticipantSids = [Participant.Sid: Bool]()
            for speaker in speakers {
                let participantSid = Participant.Sid(from: speaker.sid)
                seenParticipantSids[participantSid] = true
                if participantSid == localParticipant.sid {
                    localParticipant._state.mutate {
                        $0.audioLevel = speaker.level
                        $0.isSpeaking = true
                    }
                    activeSpeakers.append(localParticipant)
                } else {
                    if let participant = state.remoteParticipant(forSid: participantSid) {
                        participant._state.mutate {
                            $0.audioLevel = speaker.level
                            $0.isSpeaking = true
                        }
                        activeSpeakers.append(participant)
                    }
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
        let parseResult = parse(streamId: stream.streamId)
        let trackId = Track.Sid(from: track.trackId)

        let participant = _state.read {
            $0.remoteParticipants.values.first { $0.sid == parseResult.participantSid }
        }

        guard let participant else {
            log("RemoteParticipant not found for sid: \(parseResult.participantSid), remoteParticipants: \(remoteParticipants)", .warning)
            return
        }

        let task = Task.retrying(retryDelay: 0.2) { _, _ in
            // TODO: Only retry for TrackError.state = error
            try await participant.addSubscribedMediaTrack(rtcTrack: track, rtpReceiver: rtpReceiver, trackSid: trackId)
        }

        do {
            try await task.value
        } catch {
            log("addSubscribedMediaTrack failed, error: \(error)", .error)
        }
    }

    func onDidRemoveTrack(track: LKRTCMediaStreamTrack) async {
        // Find the publication
        let trackSid = Track.Sid(from: track.trackId)
        guard let publication = _state.remoteParticipants.values.map(\._state.trackPublications.values).joined()
            .first(where: { $0.sid == trackSid }) else { return }
        await publication.set(track: nil)
    }

    func onDidReceiveUserPacket(packet: Livekit_UserPacket) async {
        // participant could be null if data broadcasted from server
        let identity = Participant.Identity(from: packet.participantIdentity)
        let participant = _state.remoteParticipants[identity]

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
