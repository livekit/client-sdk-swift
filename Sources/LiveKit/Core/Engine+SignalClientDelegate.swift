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

extension Engine: SignalClientDelegate {
    func signalClient(_ signalClient: SignalClient, didUpdateConnectionState connectionState: ConnectionState, oldState: ConnectionState, disconnectError: LiveKitError?) async {
        // connectionState did update
        if connectionState != oldState,
           // did disconnect
           case .disconnected = connectionState,
           // only attempt re-connect if disconnected(reason: network)
           case .network = disconnectError?.type,
           // engine is currently connected state
           case .connected = _state.connectionState
        {
            do {
                try await startReconnect(reason: .websocket)
            } catch {
                log("Failed calling startReconnect, error: \(error)", .error)
            }
        }

        await _room?.signalClient(signalClient, didUpdateConnectionState: connectionState, oldState: oldState, disconnectError: disconnectError)
    }

    func signalClient(_ signalClient: SignalClient, didReceiveIceCandidate iceCandidate: LKRTCIceCandidate, target: Livekit_SignalTarget) async {
        guard let transport = target == .subscriber ? subscriber : publisher else {
            log("Failed to add ice candidate, transport is nil for target: \(target)", .error)
            return
        }

        do {
            try await transport.add(iceCandidate: iceCandidate)
        } catch {
            log("Failed to add ice candidate for transport: \(transport), error: \(error)", .error)
        }

        await _room?.signalClient(signalClient, didReceiveIceCandidate: iceCandidate, target: target)
    }

    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: LKRTCSessionDescription) async {
        do {
            let publisher = try requirePublisher()
            try await publisher.set(remoteDescription: answer)
        } catch {
            log("Failed to set remote description, error: \(error)", .error)
        }

        await _room?.signalClient(signalClient, didReceiveAnswer: answer)
    }

    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: LKRTCSessionDescription) async {
        log("Received offer, creating & sending answer...")

        guard let subscriber else {
            log("failed to send answer, subscriber is nil", .error)
            return
        }

        do {
            try await subscriber.set(remoteDescription: offer)
            let answer = try await subscriber.createAnswer()
            try await subscriber.set(localDescription: answer)
            try await signalClient.send(answer: answer)
        } catch {
            log("Failed to send answer with error: \(error)", .error)
        }

        await _room?.signalClient(signalClient, didReceiveOffer: offer)
    }

    func signalClient(_ signalClient: SignalClient, didUpdateToken token: String) async {
        // update token
        _state.mutate { $0.token = token }

        await _room?.signalClient(signalClient, didUpdateToken: token)
    }

    func signalClient(_ signalClient: SignalClient, didReceiveConnectResponse response: SignalClient.ConnectResponse) async {
        await _room?.signalClient(signalClient, didReceiveConnectResponse: response)
    }

    func signalClient(_ signalClient: SignalClient, didPublishLocalTrack track: Livekit_TrackPublishedResponse) async {
        await _room?.signalClient(signalClient, didPublishLocalTrack: track)
    }

    func signalClient(_ signalClient: SignalClient, didUnpublishLocalTrack track: Livekit_TrackUnpublishedResponse) async {
        await _room?.signalClient(signalClient, didUnpublishLocalTrack: track)
    }

    func signalClient(_ signalClient: SignalClient, didUpdateParticipants participants: [Livekit_ParticipantInfo]) async {
        await _room?.signalClient(signalClient, didUpdateParticipants: participants)
    }

    func signalClient(_ signalClient: SignalClient, didUpdateRoom room: Livekit_Room) async {
        await _room?.signalClient(signalClient, didUpdateRoom: room)
    }

    func signalClient(_ signalClient: SignalClient, didUpdateSpeakers speakers: [Livekit_SpeakerInfo]) async {
        await _room?.signalClient(signalClient, didUpdateSpeakers: speakers)
    }

    func signalClient(_ signalClient: SignalClient, didUpdateConnectionQuality quality: [Livekit_ConnectionQualityInfo]) async {
        await _room?.signalClient(signalClient, didUpdateConnectionQuality: quality)
    }

    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: Track.Sid, muted: Bool) async {
        await _room?.signalClient(signalClient, didUpdateRemoteMute: trackSid, muted: muted)
    }

    func signalClient(_ signalClient: SignalClient, didUpdateTrackStreamStates streamStates: [Livekit_StreamStateInfo]) async {
        await _room?.signalClient(signalClient, didUpdateTrackStreamStates: streamStates)
    }

    func signalClient(_ signalClient: SignalClient, didUpdateSubscribedCodecs codecs: [Livekit_SubscribedCodec], qualities: [Livekit_SubscribedQuality], forTrackSid trackSid: String) async {
        await _room?.signalClient(signalClient, didUpdateSubscribedCodecs: codecs, qualities: qualities, forTrackSid: trackSid)
    }

    func signalClient(_ signalClient: SignalClient, didUpdateSubscriptionPermission permission: Livekit_SubscriptionPermissionUpdate) async {
        await _room?.signalClient(signalClient, didUpdateSubscriptionPermission: permission)
    }

    func signalClient(_ signalClient: SignalClient, didReceiveLeave canReconnect: Bool, reason: Livekit_DisconnectReason) async {
        await _room?.signalClient(signalClient, didReceiveLeave: canReconnect, reason: reason)
    }
}
