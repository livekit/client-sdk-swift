/*
 * Copyright 2025 LiveKit
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

internal import LiveKitWebRTC

protocol TransportDelegate: AnyObject, Sendable {
    func transport(_ transport: Transport, didUpdateState state: LKRTCPeerConnectionState)
    func transport(_ transport: Transport, didGenerateIceCandidate iceCandidate: IceCandidate)
    func transport(_ transport: Transport, didOpenDataChannel dataChannel: LKRTCDataChannel)
    func transport(_ transport: Transport, didAddTrack track: LKRTCMediaStreamTrack, rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream])
    func transport(_ transport: Transport, didRemoveTrack track: LKRTCMediaStreamTrack)
    func transportShouldNegotiate(_ transport: Transport)
}
