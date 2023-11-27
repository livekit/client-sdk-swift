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

extension Livekit_TrackSource {

    func toLKType() -> Track.Source {
        switch self {
        case .camera: return .camera
        case .microphone: return .microphone
        case .screenShare: return .screenShareVideo
        case .screenShareAudio: return .screenShareAudio
        default: return .unknown
        }
    }
}

extension Track.Source {

    func toPBType() -> Livekit_TrackSource {
        switch self {
        case .camera: return .camera
        case .microphone: return .microphone
        case .screenShareVideo: return .screenShare
        case .screenShareAudio: return .screenShareAudio
        default: return .unknown
        }
    }
}
