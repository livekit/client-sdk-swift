/*
 * Copyright 2022 LiveKit
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

internal protocol SignalClientDelegate: AnyObject {

    func signalClient(_ signalClient: SignalClient, didMutate state: SignalClient.State, oldState: SignalClient.State) -> Bool

    func signalClient(_ signalClient: SignalClient, didReceive joinResponse: Livekit_JoinResponse) -> Bool
    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: RTCSessionDescription) -> Bool
    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: RTCSessionDescription) -> Bool
    func signalClient(_ signalClient: SignalClient, didReceive iceCandidate: RTCIceCandidate, target: Livekit_SignalTarget) -> Bool
    func signalClient(_ signalClient: SignalClient, didPublish localTrack: Livekit_TrackPublishedResponse) -> Bool
    func signalClient(_ signalClient: SignalClient, didUnpublish localTrack: Livekit_TrackUnpublishedResponse) -> Bool
    func signalClient(_ signalClient: SignalClient, didUpdate participants: [Livekit_ParticipantInfo]) -> Bool
    func signalClient(_ signalClient: SignalClient, didUpdate room: Livekit_Room) -> Bool
    func signalClient(_ signalClient: SignalClient, didUpdate speakers: [Livekit_SpeakerInfo]) -> Bool
    func signalClient(_ signalClient: SignalClient, didUpdate connectionQuality: [Livekit_ConnectionQualityInfo]) -> Bool
    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool) -> Bool
    func signalClient(_ signalClient: SignalClient, didUpdate trackStates: [Livekit_StreamStateInfo]) -> Bool
    func signalClient(_ signalClient: SignalClient, didUpdate trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) -> Bool
    func signalClient(_ signalClient: SignalClient, didUpdate subscriptionPermission: Livekit_SubscriptionPermissionUpdate) -> Bool
    func signalClient(_ signalClient: SignalClient, didUpdate token: String) -> Bool
    func signalClient(_ signalClient: SignalClient, didReceiveLeave canReconnect: Bool, reason: Livekit_DisconnectReason) -> Bool
}

// MARK: - Optional

extension SignalClientDelegate {
    func signalClient(_ signalClient: SignalClient, didMutate state: SignalClient.State, oldState: SignalClient.State) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didReceive joinResponse: Livekit_JoinResponse) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: RTCSessionDescription) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: RTCSessionDescription) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didReceive iceCandidate: RTCIceCandidate, target: Livekit_SignalTarget) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didPublish localTrack: Livekit_TrackPublishedResponse) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didUnpublish localTrack: Livekit_TrackUnpublishedResponse) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didUpdate participants: [Livekit_ParticipantInfo]) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didUpdate room: Livekit_Room) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didUpdate speakers: [Livekit_SpeakerInfo]) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didUpdate connectionQuality: [Livekit_ConnectionQualityInfo]) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didUpdate trackStates: [Livekit_StreamStateInfo]) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didUpdate trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didUpdate subscriptionPermission: Livekit_SubscriptionPermissionUpdate) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didUpdate token: String) -> Bool { false }
    func signalClient(_ signalClient: SignalClient, didReceiveLeave canReconnect: Bool, reason: Livekit_DisconnectReason) -> Bool { false }
}
