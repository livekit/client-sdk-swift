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

extension Room: SignalClientDelegate {
    func signalClient(_: SignalClient, didReceiveLeave canReconnect: Bool, reason: Livekit_DisconnectReason) {
        log("canReconnect: \(canReconnect), reason: \(reason)")

        if canReconnect {
            // force .full for next reconnect
            engine._state.mutate { $0.nextPreferredReconnectMode = .full }
        } else {
            Task {
                // Server indicates it's not recoverable
                await cleanUp(withError: LiveKitError.from(reason: reason))
            }
        }
    }

    func signalClient(_: SignalClient, didUpdateSubscribedCodecs codecs: [Livekit_SubscribedCodec],
                      qualities: [Livekit_SubscribedQuality],
                      forTrackSid trackSid: String)
    {
        log("[Publish/Backup] Qualities: \(qualities.map { String(describing: $0) }.joined(separator: ", ")), Codecs: \(codecs.map { String(describing: $0) }.joined(separator: ", "))")

        guard let publication = localParticipant.getTrackPublication(sid: trackSid) else {
            log("Received subscribed quality update for an unknown track", .warning)
            return
        }

        Task {
            if !codecs.isEmpty {
                guard let videoTrack = publication.track as? LocalVideoTrack else { return }
                let missingSubscribedCodecs = try videoTrack._set(subscribedCodecs: codecs)

                if !missingSubscribedCodecs.isEmpty {
                    log("Missing codecs: \(missingSubscribedCodecs)")
                    for missingSubscribedCodec in missingSubscribedCodecs {
                        do {
                            log("Publishing additional codec: \(missingSubscribedCodec)")
                            try await localParticipant.publish(additionalVideoCodec: missingSubscribedCodec, for: publication)
                        } catch {
                            log("Failed publishing additional codec: \(missingSubscribedCodec), error: \(error)", .error)
                        }
                    }
                }

            } else {
                localParticipant._set(subscribedQualities: qualities, forTrackSid: trackSid)
            }
        }
    }

    func signalClient(_: SignalClient, didReceiveConnectResponse connectResponse: SignalClient.ConnectResponse) {
        if case let .join(joinResponse) = connectResponse {
            log("\(joinResponse.serverInfo)", .info)

            if e2eeManager != nil, !joinResponse.sifTrailer.isEmpty {
                e2eeManager?.keyProvider.setSifTrailer(trailer: joinResponse.sifTrailer)
            }

            _state.mutate {
                $0.sid = joinResponse.room.sid
                $0.name = joinResponse.room.name
                $0.metadata = joinResponse.room.metadata
                $0.isRecording = joinResponse.room.activeRecording
                $0.serverInfo = joinResponse.serverInfo

                localParticipant.updateFromInfo(info: joinResponse.participant)

                if !joinResponse.otherParticipants.isEmpty {
                    for otherParticipant in joinResponse.otherParticipants {
                        $0.updateRemoteParticipant(info: otherParticipant, room: self)
                    }
                }
            }
        }
    }

    func signalClient(_: SignalClient, didUpdateRoom room: Livekit_Room) {
        _state.mutate {
            $0.metadata = room.metadata
            $0.isRecording = room.activeRecording
            $0.maxParticipants = Int(room.maxParticipants)
            $0.numParticipants = Int(room.numParticipants)
            $0.numPublishers = Int(room.numPublishers)
        }
    }

    func signalClient(_: SignalClient, didUpdateSpeakers speakers: [Livekit_SpeakerInfo]) {
        log("speakers: \(speakers)", .trace)

        let activeSpeakers = _state.mutate { state -> [Participant] in

            var lastSpeakers = state.activeSpeakers.reduce(into: [Sid: Participant]()) { $0[$1.sid] = $1 }
            for speaker in speakers {
                guard let participant = speaker.sid == localParticipant.sid ? localParticipant : state.remoteParticipant(sid: speaker.sid) else {
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
            guard let self else { return }

            self.delegates.notify(label: { "room.didUpdate speakers: \(speakers)" }) {
                $0.room?(self, didUpdateSpeakingParticipants: activeSpeakers)
            }
        }
    }

    func signalClient(_: SignalClient, didUpdateConnectionQuality connectionQuality: [Livekit_ConnectionQualityInfo]) {
        log("connectionQuality: \(connectionQuality)", .trace)

        for entry in connectionQuality {
            if entry.participantSid == localParticipant.sid {
                // update for LocalParticipant
                localParticipant._state.mutate { $0.connectionQuality = entry.quality.toLKType() }
            } else if let participant = _state.read({ $0.remoteParticipant(sid: entry.participantSid) }) {
                // udpate for RemoteParticipant
                participant._state.mutate { $0.connectionQuality = entry.quality.toLKType() }
            }
        }
    }

    func signalClient(_: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool) {
        log("trackSid: \(trackSid) isMuted: \(muted)")

        guard let publication = localParticipant._state.trackPublications[trackSid] as? LocalTrackPublication else {
            // publication was not found but the delegate was handled
            return
        }

        Task {
            if muted {
                try await publication.mute()
            } else {
                try await publication.unmute()
            }
        }
    }

    func signalClient(_: SignalClient, didUpdateSubscriptionPermission subscriptionPermission: Livekit_SubscriptionPermissionUpdate) {
        log("did update subscriptionPermission: \(subscriptionPermission)")

        guard let participant = _state.read({ $0.remoteParticipant(sid: subscriptionPermission.participantSid) }),
              let publication = participant.getTrackPublication(sid: subscriptionPermission.trackSid)
        else {
            return
        }

        publication.set(subscriptionAllowed: subscriptionPermission.allowed)
    }

    func signalClient(_: SignalClient, didUpdateTrackStreamStates trackStates: [Livekit_StreamStateInfo]) {
        log("did update trackStates: \(trackStates.map { "(\($0.trackSid): \(String(describing: $0.state)))" }.joined(separator: ", "))")

        for update in trackStates {
            // Try to find RemoteParticipant
            guard let participant = _state.remoteParticipants[update.participantSid] else { continue }
            // Try to find RemoteTrackPublication
            guard let trackPublication = participant._state.trackPublications[update.trackSid] as? RemoteTrackPublication else { continue }
            // Update streamState (and notify)
            trackPublication._state.mutate { $0.streamState = update.state.toLKType() }
        }
    }

    func signalClient(_: SignalClient, didUpdateParticipants participants: [Livekit_ParticipantInfo]) {
        log("participants: \(participants)")

        var disconnectedParticipantIdentities = [Identity]()
        var newParticipants = [RemoteParticipant]()

        _state.mutate {
            for info in participants {
                if info.sid == localParticipant.sid {
                    localParticipant.updateFromInfo(info: info)
                    continue
                }

                if info.state == .disconnected {
                    // when it's disconnected, send updates
                    disconnectedParticipantIdentities.append(info.identity)
                } else {
                    let isNewParticipant = $0.remoteParticipant(sid: info.sid) == nil
                    let participant = $0.updateRemoteParticipant(info: info, room: self)

                    if isNewParticipant {
                        newParticipants.append(participant)
                    } else {
                        participant.updateFromInfo(info: info)
                    }
                }
            }
        }

        for identity in disconnectedParticipantIdentities {
            Task {
                try await _onParticipantDidDisconnect(identity: identity)
            }
        }

        for participant in newParticipants {
            engine.executeIfConnected { [weak self] in
                guard let self else { return }

                self.delegates.notify(label: { "room.remoteParticipantDidConnect: \(participant)" }) {
                    $0.room?(self, participantDidConnect: participant)
                }
            }
        }
    }

    func signalClient(_: SignalClient, didUnpublishLocalTrack localTrack: Livekit_TrackUnpublishedResponse) {
        log()

        guard let publication = localParticipant._state.trackPublications[localTrack.trackSid] as? LocalTrackPublication else {
            log("track publication not found", .warning)
            return
        }

        Task {
            do {
                try await localParticipant.unpublish(publication: publication)
                log("Unpublished track(\(localTrack.trackSid)")
            } catch {
                log("Failed to unpublish track(\(localTrack.trackSid), error: \(error)", .warning)
            }
        }
    }

    func signalClient(_: SignalClient, didMutateState _: SignalClient.State, oldState _: SignalClient.State) {}
    func signalClient(_: SignalClient, didReceiveAnswer _: LKRTCSessionDescription) {}
    func signalClient(_: SignalClient, didReceiveOffer _: LKRTCSessionDescription) {}
    func signalClient(_: SignalClient, didReceiveIceCandidate _: LKRTCIceCandidate, target _: Livekit_SignalTarget) {}
    func signalClient(_: SignalClient, didPublishLocalTrack _: Livekit_TrackPublishedResponse) {}
    func signalClient(_: SignalClient, didUpdateToken _: String) {}
}
