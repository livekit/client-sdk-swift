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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

protocol TransportDelegate: AnyObject {
    func transport(_ transport: Transport, didUpdateState state: RTCPeerConnectionState) async
    func transport(_ transport: Transport, didGenerateIceCandidate iceCandidate: LKRTCIceCandidate) async
    func transport(_ transport: Transport, didOpenDataChannel dataChannel: LKRTCDataChannel) async
    func transport(_ transport: Transport, didAddTrack track: LKRTCMediaStreamTrack, rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) async
    func transport(_ transport: Transport, didRemoveTrack track: LKRTCMediaStreamTrack) async
    func transportShouldNegotiate(_ transport: Transport) async
}
