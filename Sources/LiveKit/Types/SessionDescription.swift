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

extension RTCSessionDescription {

    func toPBType() -> Livekit_SessionDescription {
        var sd = Livekit_SessionDescription()
        sd.sdp = sdp

        switch type {
        case .answer: sd.type = "answer"
        case .offer: sd.type = "offer"
        case .prAnswer: sd.type = "pranswer"
        default: fatalError("Unknown state \(type)") // This should never happen
        }

        return sd
    }
}

extension Livekit_SessionDescription {

    func toRTCType() -> RTCSessionDescription {
        var sdpType: RTCSdpType
        switch type {
        case "answer": sdpType = .answer
        case "offer": sdpType = .offer
        case "pranswer": sdpType = .prAnswer
        default: fatalError("Unknown state \(type)") // This should never happen
        }

        return Engine.createSessionDescription(type: sdpType, sdp: sdp)
    }
}
