import WebRTC

extension RTCSessionDescription {

    func toPBType() -> Livekit_SessionDescription {
        var sd = Livekit_SessionDescription()
        sd.sdp = sdp

        switch type {
        case .answer: sd.type = "answer"
        case .offer: sd.type = "offer"
        case .prAnswer: sd.type = "pranswer"
        default:
            // This should never happen
            fatalError("Unknown state \(type)")
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
        default:
            // This should never happen
            fatalError("Unknown state \(type)")
        }

        return RTCSessionDescription(type: sdpType, sdp: sdp)
    }
}
