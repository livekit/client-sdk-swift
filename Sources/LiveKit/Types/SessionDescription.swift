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
