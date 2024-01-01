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

protocol SignalClientDelegate: AnyObject {
    func signalClient(_ signalClient: SignalClient, didMutateState state: SignalClient.State, oldState: SignalClient.State)
    func signalClient(_ signalClient: SignalClient, didReceiveConnectResponse connectResponse: SignalClient.ConnectResponse)
    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: LKRTCSessionDescription)
    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: LKRTCSessionDescription)
    func signalClient(_ signalClient: SignalClient, didReceiveIceCandidate iceCandidate: LKRTCIceCandidate, target: Livekit_SignalTarget)
    func signalClient(_ signalClient: SignalClient, didPublishLocalTrack localTrack: Livekit_TrackPublishedResponse)
    func signalClient(_ signalClient: SignalClient, didUnpublishLocalTrack localTrack: Livekit_TrackUnpublishedResponse)
    func signalClient(_ signalClient: SignalClient, didUpdateParticipants participants: [Livekit_ParticipantInfo])
    func signalClient(_ signalClient: SignalClient, didUpdateRoom room: Livekit_Room)
    func signalClient(_ signalClient: SignalClient, didUpdateSpeakers speakers: [Livekit_SpeakerInfo])
    func signalClient(_ signalClient: SignalClient, didUpdateConnectionQuality connectionQuality: [Livekit_ConnectionQualityInfo])
    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool)
    func signalClient(_ signalClient: SignalClient, didUpdateTrackStreamStates streamStates: [Livekit_StreamStateInfo])
    func signalClient(_ signalClient: SignalClient, didUpdateSubscribedCodecs codecs: [Livekit_SubscribedCodec], qualities: [Livekit_SubscribedQuality], forTrackSid sid: String)
    func signalClient(_ signalClient: SignalClient, didUpdateSubscriptionPermission permission: Livekit_SubscriptionPermissionUpdate)
    func signalClient(_ signalClient: SignalClient, didUpdateToken token: String)
    func signalClient(_ signalClient: SignalClient, didReceiveLeave canReconnect: Bool, reason: Livekit_DisconnectReason)
}
