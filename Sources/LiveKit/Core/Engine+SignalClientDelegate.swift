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

@_implementationOnly import WebRTC

extension Engine: SignalClientDelegate {

    func signalClient(_ signalClient: SignalClient, didMutate state: SignalClient.State, oldState: SignalClient.State) {

        // connectionState did update
        if state.connectionState != oldState.connectionState,
           // did disconnect
           case .disconnected(let reason) = state.connectionState,
           // only attempt re-connect if disconnected(reason: network)
           case .networkError = reason,
           // engine is currently connected state
           case .connected = _state.connectionState {
            log("[reconnect] starting, reason: socket network error. connectionState: \(_state.connectionState)")
            Task {
                try await startReconnect()
            }
        }
    }

    func signalClient(_ signalClient: SignalClient, didReceive iceCandidate: LKRTCIceCandidate, target: Livekit_SignalTarget) {

        guard let transport = target == .subscriber ? subscriber : publisher else {
            log("Failed to add ice candidate, transport is nil for target: \(target)", .error)
            return
        }

        Task {
            do {
                try await transport.add(iceCandidate: iceCandidate)
            } catch let error {
                log("Failed to add ice candidate for transport: \(transport), error: \(error)", .error)
            }
        }
    }

    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: LKRTCSessionDescription) {
        Task {
            do {
                let publisher = try await requirePublisher()
                try await publisher.set(remoteDescription: answer)
            } catch let error {
                log("Failed to set remote description, error: \(error)", .error)
            }
        }
    }

    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: LKRTCSessionDescription) {

        log("Received offer, creating & sending answer...")

        guard let subscriber = self.subscriber else {
            log("failed to send answer, subscriber is nil", .error)
            return
        }

        Task {
            do {
                try await subscriber.set(remoteDescription: offer)
                let answer = try await subscriber.createAnswer()
                try await subscriber.set(localDescription: answer)
                try await signalClient.send(answer: answer)
            } catch let error {
                log("Failed to send answer with error: \(error)", .error)
            }
        }
    }

    func signalClient(_ signalClient: SignalClient, didUpdate token: String) {

        // update token
        _state.mutate { $0.token = token }
    }

    func signalClient(_ signalClient: SignalClient, didReceive joinResponse: Livekit_JoinResponse) {}
    func signalClient(_ signalClient: SignalClient, didPublish localTrack: Livekit_TrackPublishedResponse) {}
    func signalClient(_ signalClient: SignalClient, didUnpublish localTrack: Livekit_TrackUnpublishedResponse) {}
    func signalClient(_ signalClient: SignalClient, didUpdate participants: [Livekit_ParticipantInfo]) {}
    func signalClient(_ signalClient: SignalClient, didUpdate room: Livekit_Room) {}
    func signalClient(_ signalClient: SignalClient, didUpdate speakers: [Livekit_SpeakerInfo]) {}
    func signalClient(_ signalClient: SignalClient, didUpdate connectionQuality: [Livekit_ConnectionQualityInfo]) {}
    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool) {}
    func signalClient(_ signalClient: SignalClient, didUpdate trackStates: [Livekit_StreamStateInfo]) {}
    func signalClient(_ signalClient: SignalClient, didUpdate trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) {}
    func signalClient(_ signalClient: SignalClient, didUpdate subscriptionPermission: Livekit_SubscriptionPermissionUpdate) {}
    func signalClient(_ signalClient: SignalClient, didReceiveLeave canReconnect: Bool, reason: Livekit_DisconnectReason) {}
}
