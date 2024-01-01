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
    func signalClient(_: SignalClient, didMutateState state: SignalClient.State, oldState: SignalClient.State) {
        // connectionState did update
        if state.connectionState != oldState.connectionState,
           // did disconnect
           case .disconnected = state.connectionState,
           // only attempt re-connect if disconnected(reason: network)
           case .network = state.disconnectError?.type,
           // engine is currently connected state
           case .connected = _state.connectionState
        {
            Task {
                try await startReconnect(reason: .websocket)
            }
        }
    }

    func signalClient(_: SignalClient, didReceiveIceCandidate iceCandidate: LKRTCIceCandidate, target: Livekit_SignalTarget) {
        guard let transport = target == .subscriber ? subscriber : publisher else {
            log("Failed to add ice candidate, transport is nil for target: \(target)", .error)
            return
        }

        Task {
            do {
                try await transport.add(iceCandidate: iceCandidate)
            } catch {
                log("Failed to add ice candidate for transport: \(transport), error: \(error)", .error)
            }
        }
    }

    func signalClient(_: SignalClient, didReceiveAnswer answer: LKRTCSessionDescription) {
        Task {
            do {
                let publisher = try requirePublisher()
                try await publisher.set(remoteDescription: answer)
            } catch {
                log("Failed to set remote description, error: \(error)", .error)
            }
        }
    }

    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: LKRTCSessionDescription) {
        log("Received offer, creating & sending answer...")

        guard let subscriber else {
            log("failed to send answer, subscriber is nil", .error)
            return
        }

        Task {
            do {
                try await subscriber.set(remoteDescription: offer)
                let answer = try await subscriber.createAnswer()
                try await subscriber.set(localDescription: answer)
                try await signalClient.send(answer: answer)
            } catch {
                log("Failed to send answer with error: \(error)", .error)
            }
        }
    }

    func signalClient(_: SignalClient, didUpdateToken token: String) {
        // update token
        _state.mutate { $0.token = token }
    }

    func signalClient(_: SignalClient, didReceiveConnectResponse _: SignalClient.ConnectResponse) {}
    func signalClient(_: SignalClient, didPublishLocalTrack _: Livekit_TrackPublishedResponse) {}
    func signalClient(_: SignalClient, didUnpublishLocalTrack _: Livekit_TrackUnpublishedResponse) {}
    func signalClient(_: SignalClient, didUpdateParticipants _: [Livekit_ParticipantInfo]) {}
    func signalClient(_: SignalClient, didUpdateRoom _: Livekit_Room) {}
    func signalClient(_: SignalClient, didUpdateSpeakers _: [Livekit_SpeakerInfo]) {}
    func signalClient(_: SignalClient, didUpdateConnectionQuality _: [Livekit_ConnectionQualityInfo]) {}
    func signalClient(_: SignalClient, didUpdateRemoteMute _: String, muted _: Bool) {}
    func signalClient(_: SignalClient, didUpdateTrackStreamStates _: [Livekit_StreamStateInfo]) {}
    func signalClient(_: SignalClient, didUpdateSubscribedCodecs _: [Livekit_SubscribedCodec], qualities _: [Livekit_SubscribedQuality], forTrackSid _: String) {}
    func signalClient(_: SignalClient, didUpdateSubscriptionPermission _: Livekit_SubscriptionPermissionUpdate) {}
    func signalClient(_: SignalClient, didReceiveLeave _: Bool, reason _: Livekit_DisconnectReason) {}
}
