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
    func signalClient(_: SignalClient, didUpdateConnectionState connectionState: ConnectionState, oldState: ConnectionState, disconnectError: LiveKitError?) async {
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
    }

    func signalClient(_: SignalClient, didReceiveIceCandidate iceCandidate: LKRTCIceCandidate, target: Livekit_SignalTarget) async {
        guard let transport = target == .subscriber ? subscriber : publisher else {
            log("Failed to add ice candidate, transport is nil for target: \(target)", .error)
            return
        }

        do {
            try await transport.add(iceCandidate: iceCandidate)
        } catch {
            log("Failed to add ice candidate for transport: \(transport), error: \(error)", .error)
        }
    }

    func signalClient(_: SignalClient, didReceiveAnswer answer: LKRTCSessionDescription) async {
        do {
            let publisher = try requirePublisher()
            try await publisher.set(remoteDescription: answer)
        } catch {
            log("Failed to set remote description, error: \(error)", .error)
        }
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
    }

    func signalClient(_: SignalClient, didUpdateToken token: String) async {
        // update token
        _state.mutate { $0.token = token }
    }

    func signalClient(_: SignalClient, didReceiveConnectResponse _: SignalClient.ConnectResponse) async {}

    func signalClient(_: SignalClient, didPublishLocalTrack _: Livekit_TrackPublishedResponse) async {}

    func signalClient(_: SignalClient, didUnpublishLocalTrack _: Livekit_TrackUnpublishedResponse) async {}

    func signalClient(_: SignalClient, didUpdateParticipants _: [Livekit_ParticipantInfo]) async {}

    func signalClient(_: SignalClient, didUpdateRoom _: Livekit_Room) async {}

    func signalClient(_: SignalClient, didUpdateSpeakers _: [Livekit_SpeakerInfo]) async {}

    func signalClient(_: SignalClient, didUpdateConnectionQuality _: [Livekit_ConnectionQualityInfo]) async {}

    func signalClient(_: SignalClient, didUpdateRemoteMute _: String, muted _: Bool) async {}

    func signalClient(_: SignalClient, didUpdateTrackStreamStates _: [Livekit_StreamStateInfo]) async {}

    func signalClient(_: SignalClient, didUpdateSubscribedCodecs _: [Livekit_SubscribedCodec], qualities _: [Livekit_SubscribedQuality], forTrackSid _: String) async {}

    func signalClient(_: SignalClient, didUpdateSubscriptionPermission _: Livekit_SubscriptionPermissionUpdate) async {}

    func signalClient(_: SignalClient, didReceiveLeave _: Bool, reason _: Livekit_DisconnectReason) async {}
}
