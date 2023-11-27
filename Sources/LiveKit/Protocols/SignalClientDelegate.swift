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

    func signalClient(_ signalClient: SignalClient, didMutate state: SignalClient.State, oldState: SignalClient.State)

    func signalClient(_ signalClient: SignalClient, didReceive joinResponse: Livekit_JoinResponse)
    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: RTCSessionDescription)
    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: RTCSessionDescription)
    func signalClient(_ signalClient: SignalClient, didReceive iceCandidate: RTCIceCandidate, target: Livekit_SignalTarget)
    func signalClient(_ signalClient: SignalClient, didPublish localTrack: Livekit_TrackPublishedResponse)
    func signalClient(_ signalClient: SignalClient, didUnpublish localTrack: Livekit_TrackUnpublishedResponse)
    func signalClient(_ signalClient: SignalClient, didUpdate participants: [Livekit_ParticipantInfo])
    func signalClient(_ signalClient: SignalClient, didUpdate room: Livekit_Room)
    func signalClient(_ signalClient: SignalClient, didUpdate speakers: [Livekit_SpeakerInfo])
    func signalClient(_ signalClient: SignalClient, didUpdate connectionQuality: [Livekit_ConnectionQualityInfo])
    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool)
    func signalClient(_ signalClient: SignalClient, didUpdate trackStates: [Livekit_StreamStateInfo])
    func signalClient(_ signalClient: SignalClient, didUpdate trackSid: String, subscribedQualities: [Livekit_SubscribedQuality])
    func signalClient(_ signalClient: SignalClient, didUpdate subscriptionPermission: Livekit_SubscriptionPermissionUpdate)
    func signalClient(_ signalClient: SignalClient, didUpdate token: String)
    func signalClient(_ signalClient: SignalClient, didReceiveLeave canReconnect: Bool, reason: Livekit_DisconnectReason)
}
