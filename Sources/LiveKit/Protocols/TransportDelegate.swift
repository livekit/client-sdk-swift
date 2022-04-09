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

internal protocol TransportDelegate: AnyObject {
    func transport(_ transport: Transport, didUpdate state: RTCPeerConnectionState)
    func transport(_ transport: Transport, didGenerate iceCandidate: RTCIceCandidate)
    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel)
    func transport(_ transport: Transport, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream])
    func transport(_ transport: Transport, didRemove track: RTCMediaStreamTrack)
    func transportShouldNegotiate(_ transport: Transport)
    func transport(_ transport: Transport, didGenerate stats: [TrackStats], target: Livekit_SignalTarget)
}
