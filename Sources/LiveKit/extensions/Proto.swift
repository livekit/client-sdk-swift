//
//  File.swift
//  
//
//  Created by Hiroshi Horie on 2021/10/06.
//

import WebRTC

//
// Protobuf types <-> RTC types
//

extension Livekit_SessionDescription {

    func toRTCType() throws -> RTCSessionDescription {
        var rtcSdpType: RTCSdpType
        switch type {
        case "answer":
            rtcSdpType = .answer
        case "offer":
            rtcSdpType = .offer
        case "pranswer":
            rtcSdpType = .prAnswer
        default:
            throw SignalClientError.invalidRTCSdpType
        }

        return RTCSessionDescription(type: rtcSdpType, sdp: sdp)
    }
}


extension RTCSessionDescription {

    func toPBType() throws -> Livekit_SessionDescription {

        var sessionDescription = Livekit_SessionDescription()
        sessionDescription.sdp = sdp

        switch type {
        case .answer:
            sessionDescription.type = "answer"
        case .offer:
            sessionDescription.type = "offer"
        case .prAnswer:
            sessionDescription.type = "pranswer"
        default:
            throw SignalClientError.invalidRTCSdpType
        }

        return sessionDescription
    }
}
