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

internal protocol EngineDelegate: AnyObject {
    func engine(_ engine: Engine, didMutate state: Engine.State, oldState: Engine.State)
    func engine(_ engine: Engine, didUpdate speakers: [Livekit_SpeakerInfo])
    func engine(_ engine: Engine, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream])
    func engine(_ engine: Engine, didRemove track: RTCMediaStreamTrack)
    func engine(_ engine: Engine, didReceive userPacket: Livekit_UserPacket)
    func engine(_ engine: Engine, didGenerate stats: [TrackStats], target: Livekit_SignalTarget)
}
