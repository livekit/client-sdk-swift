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
import Promises
import WebRTC

extension Engine: SignalClientDelegate {
    func signalClient(_: SignalClient, didMutate state: SignalClient.State, oldState: SignalClient.State) {
        // connectionState did update
        if state.connectionState != oldState.connectionState,
           // did disconnect
           case let .disconnected(reason) = state.connectionState,
           // only attempt re-connect if disconnected(reason: network)
           case .networkError = reason,
           // engine is currently connected state
           case .connected = _state.connectionState
        {
            log("[reconnect] starting, reason: socket network error. connectionState: \(_state.connectionState)")
            startReconnect()
        }
    }

    func signalClient(_: SignalClient, didReceive iceCandidate: RTCIceCandidate, target: Livekit_SignalTarget) {
        guard let transport = target == .subscriber ? subscriber : publisher else {
            log("failed to add ice candidate, transport is nil for target: \(target)", .error)
            return
        }

        transport.addIceCandidate(iceCandidate).catch(on: queue) { error in
            self.log("failed to add ice candidate for transport: \(transport), error: \(error)", .error)
        }
    }

    func signalClient(_: SignalClient, didReceiveAnswer answer: RTCSessionDescription) {
        guard let publisher else {
            log("publisher is nil", .error)
            return
        }

        publisher.setRemoteDescription(answer).catch(on: queue) { error in
            self.log("failed to set remote description, error: \(error)", .error)
        }
    }

    func signalClient(_: SignalClient, didReceiveOffer offer: RTCSessionDescription) {
        log("received offer, creating & sending answer...")

        guard let subscriber else {
            log("failed to send answer, subscriber is nil", .error)
            return
        }

        subscriber.setRemoteDescription(offer).then(on: queue) {
            subscriber.createAnswer()
        }.then(on: queue) { answer in
            subscriber.setLocalDescription(answer)
        }.then(on: queue) { answer in
            self.signalClient.sendAnswer(answer: answer)
        }.then(on: queue) {
            self.log("answer sent to signal")
        }.catch(on: queue) { error in
            self.log("failed to send answer, error: \(error)", .error)
        }
    }

    func signalClient(_: SignalClient, didUpdate token: String) {
        // update token
        _state.mutate { $0.token = token }
    }

    func signalClient(_: SignalClient, didReceive _: Livekit_JoinResponse) {}
    func signalClient(_: SignalClient, didPublish _: Livekit_TrackPublishedResponse) {}
    func signalClient(_: SignalClient, didUnpublish _: Livekit_TrackUnpublishedResponse) {}
    func signalClient(_: SignalClient, didUpdate _: [Livekit_ParticipantInfo]) {}
    func signalClient(_: SignalClient, didUpdate _: Livekit_Room) {}
    func signalClient(_: SignalClient, didUpdate _: [Livekit_SpeakerInfo]) {}
    func signalClient(_: SignalClient, didUpdate _: [Livekit_ConnectionQualityInfo]) {}
    func signalClient(_: SignalClient, didUpdateRemoteMute _: String, muted _: Bool) {}
    func signalClient(_: SignalClient, didUpdate _: [Livekit_StreamStateInfo]) {}
    func signalClient(_: SignalClient, didUpdate _: String, subscribedQualities _: [Livekit_SubscribedQuality]) {}
    func signalClient(_: SignalClient, didUpdate _: Livekit_SubscriptionPermissionUpdate) {}
    func signalClient(_: SignalClient, didReceiveLeave _: Bool, reason _: Livekit_DisconnectReason) {}
}
