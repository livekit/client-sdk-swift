import WebRTC

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
            throw InternalError.state(message: "Unknown state \(type)")
        }

        return sessionDescription
    }
}

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
            throw InternalError.state(message: "Unknown state \(type)")
        }

        return RTCSessionDescription(type: rtcSdpType, sdp: sdp)
    }
}
