/*
 * Copyright 2026 LiveKit
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

#if LK_XCFRAMEWORK
internal import CLiveKitProto
#elseif !COCOAPODS
import CLiveKitProto
import LiveKitNanopb
#endif
internal import LiveKitWebRTC

extension LKRTCSessionDescription {
    func toPBType(offerId: UInt32) -> Livekit_SessionDescription {
        Livekit_SessionDescription.with {
            $0.sdp = sdp
            $0.id = offerId

            switch type {
            case .answer: $0.type = "answer"
            case .offer: $0.type = "offer"
            case .prAnswer: $0.type = "pranswer"
            default: fatalError("Unknown state \(type)") // This should never happen
            }
        }
    }
}

extension NanopbMsg where S == livekit_SessionDescription {
    func toRTCType() -> (LKRTCSessionDescription, UInt32) {
        var sdpType: LKRTCSdpType
        switch type {
        case "answer": sdpType = .answer
        case "offer": sdpType = .offer
        case "pranswer": sdpType = .prAnswer
        default: fatalError("Unknown state \(type)") // This should never happen
        }

        return (RTC.createSessionDescription(type: sdpType, sdp: sdp), id)
    }
}
