/*
 * Copyright 2023 LiveKit
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
import WebRTC
import Promises

extension Room: SignalClientDelegate {

    func signalClient(_ signalClient: SignalClient, didReceiveLeave canReconnect: Bool, reason: Livekit_DisconnectReason) {

        log("canReconnect: \(canReconnect), reason: \(reason)")

        if canReconnect {
            // force .full for next reconnect
            engine._state.mutate { $0.nextPreferredReconnectMode = .full }
        } else {
            // server indicates it's not recoverable
            cleanUp(reason: reason.toLKType())
        }
    }

    func signalClient(_ signalClient: SignalClient, didUpdate trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) {

        log("qualities: \(subscribedQualities.map({ String(describing: $0) }).joined(separator: ", "))")

        guard let localParticipant = _state.localParticipant else { return }
        localParticipant.onSubscribedQualitiesUpdate(trackSid: trackSid, subscribedQualities: subscribedQualities)
    }

    func signalClient(_ signalClient: SignalClient, didReceive joinResponse: Livekit_JoinResponse) {

        if e2eeManager != nil, !joinResponse.sifTrailer.isEmpty {
            e2eeManager?.keyProvider.setSifTrailer(trailer: joinResponse.sifTrailer)
        }

        _state.mutate {
            $0.sid = joinResponse.room.sid
            $0.name = joinResponse.room.name
            $0.metadata = joinResponse.room.metadata
            $0.serverVersion = joinResponse.serverVersion
            $0.serverRegion = joinResponse.serverRegion.isEmpty ? nil : joinResponse.serverRegion
            $0.isRecording = joinResponse.room.activeRecording

            if joinResponse.hasParticipant {
                $0.localParticipant = LocalParticipant(from: joinResponse.participant, room: self)
            }

            if !joinResponse.otherParticipants.isEmpty {
                for otherParticipant in joinResponse.otherParticipants {
                    $0.getOrCreateRemoteParticipant(sid: otherParticipant.sid, info: otherParticipant, room: self)
                }
            }
        }
    }

    func signalClient(_ signalClient: SignalClient, didUpdate room: Livekit_Room) {
        _state.mutate {
            $0.metadata = room.metadata
            $0.isRecording = room.activeRecording
            $0.maxParticipants = Int(room.maxParticipants)
            $0.numParticipants = Int(room.numParticipants)
            $0.numPublishers = Int(room.numPublishers)
        }
    }

    func signalClient(_ signalClient: SignalClient, didUpdate speakers: [Livekit_SpeakerInfo]) {
        log("speakers: \(speakers)", .trace)

        let activeSpeakers = _state.mutate { state -> [Participant] in

            var lastSpeakers = state.activeSpeakers.reduce(into: [Sid: Participant]()) { $0[$1.sid] = $1 }
            for speaker in speakers {

                guard let participant = speaker.sid == state.localParticipant?.sid ? state.localParticipant : state.remoteParticipants[speaker.sid] else {
                    continue
                }

                participant._state.mutate {
                    $0.audioLevel = speaker.level
                    $0.isSpeaking = speaker.active
                }

                if speaker.active {
                    lastSpeakers[speaker.sid] = participant
                } else {
                    lastSpeakers.removeValue(forKey: speaker.sid)
                }
            }

            state.activeSpeakers = lastSpeakers.values.sorted(by: { $1.audioLevel > $0.audioLevel })

            return state.activeSpeakers
        }

        engine.executeIfConnected { [weak self] in
            guard let self = self else { return }

            self.delegates.notify(label: { "room.didUpdate speakers: \(speakers)" }) {
                $0.room?(self, didUpdate: activeSpeakers)
            }
        }
    }

    func signalClient(_ signalClient: SignalClient, didUpdate connectionQuality: [Livekit_ConnectionQualityInfo]) {
        log("connectionQuality: \(connectionQuality)", .trace)

        for entry in connectionQuality {
            if let localParticipant = _state.localParticipant,
               entry.participantSid == localParticipant.sid {
                // update for LocalParticipant
                localParticipant._state.mutate { $0.connectionQuality = entry.quality.toLKType() }
            } else if let participant = _state.remoteParticipants[entry.participantSid] {
                // udpate for RemoteParticipant
                participant._state.mutate { $0.connectionQuality = entry.quality.toLKType() }
            }
        }
    }

    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool) {
        log("trackSid: \(trackSid) muted: \(muted)")

        guard let publication = _state.localParticipant?._state.tracks[trackSid] as? LocalTrackPublication else {
            // publication was not found but the delegate was handled
            return
        }

        if muted {
            publication.mute()
        } else {
            publication.unmute()
        }
    }

    func signalClient(_ signalClient: SignalClient, didUpdate subscriptionPermission: Livekit_SubscriptionPermissionUpdate) {

        log("did update subscriptionPermission: \(subscriptionPermission)")

        guard let participant = _state.remoteParticipants[subscriptionPermission.participantSid],
              let publication = participant.getTrackPublication(sid: subscriptionPermission.trackSid) else {
            return
        }

        publication.set(subscriptionAllowed: subscriptionPermission.allowed)
    }

    func signalClient(_ signalClient: SignalClient, didUpdate trackStates: [Livekit_StreamStateInfo]) {

        log("did update trackStates: \(trackStates.map { "(\($0.trackSid): \(String(describing: $0.state)))" }.joined(separator: ", "))")

        for update in trackStates {
            // Try to find RemoteParticipant
            guard let participant = _state.remoteParticipants[update.participantSid] else { continue }
            // Try to find RemoteTrackPublication
            guard let trackPublication = participant._state.tracks[update.trackSid] as? RemoteTrackPublication else { continue }
            // Update streamState (and notify)
            trackPublication._state.mutate { $0.streamState = update.state.toLKType() }
        }
    }

    func signalClient(_ signalClient: SignalClient, didUpdate participants: [Livekit_ParticipantInfo]) {
        log("participants: \(participants)")

        var disconnectedParticipants = [Sid]()
        var newParticipants = [RemoteParticipant]()

        _state.mutate {

            for info in participants {

                if info.sid == $0.localParticipant?.sid {
                    $0.localParticipant?.updateFromInfo(info: info)
                    continue
                }

                if info.state == .disconnected {
                    // when it's disconnected, send updates
                    disconnectedParticipants.append(info.sid)
                } else {

                    let isNewParticipant = $0.remoteParticipants[info.sid] == nil
                    let participant = $0.getOrCreateRemoteParticipant(sid: info.sid, info: info, room: self)

                    if isNewParticipant {
                        newParticipants.append(participant)
                    } else {
                        participant.updateFromInfo(info: info)
                    }
                }
            }
        }

        for sid in disconnectedParticipants {
            onParticipantDisconnect(sid: sid)
        }

        for participant in newParticipants {

            engine.executeIfConnected { [weak self] in
                guard let self = self else { return }

                self.delegates.notify(label: { "room.participantDidJoin participant: \(participant)" }) {
                    $0.room?(self, participantDidJoin: participant)
                }
            }
        }
    }

    func signalClient(_ signalClient: SignalClient, didUnpublish localTrack: Livekit_TrackUnpublishedResponse) {
        log()

        guard let localParticipant = localParticipant,
              let publication = localParticipant._state.tracks[localTrack.trackSid] as? LocalTrackPublication else {
            log("track publication not found", .warning)
            return
        }

        localParticipant.unpublish(publication: publication).then(on: queue) { [weak self] _ in
            self?.log("unpublished track(\(localTrack.trackSid)")
        }.catch(on: queue) { [weak self] error in
            self?.log("failed to unpublish track(\(localTrack.trackSid), error: \(error)", .warning)
        }
    }

    func signalClient(_ signalClient: SignalClient, didMutate state: SignalClient.State, oldState: SignalClient.State) {}
    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: RTCSessionDescription) {}
    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: RTCSessionDescription) {}
    func signalClient(_ signalClient: SignalClient, didReceive iceCandidate: RTCIceCandidate, target: Livekit_SignalTarget) {}
    func signalClient(_ signalClient: SignalClient, didPublish localTrack: Livekit_TrackPublishedResponse) {}
    func signalClient(_ signalClient: SignalClient, didUpdate token: String) {}
}
