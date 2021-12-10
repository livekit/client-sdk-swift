import WebRTC

extension RTCConfiguration {

    public static let defaultIceServers = ["stun:stun.l.google.com:19302",
                                           "stun:stun1.l.google.com:19302"]

    public static func liveKitDefault() -> RTCConfiguration {

        let result = RTCConfiguration()
        result.sdpSemantics = .unifiedPlan
        result.continualGatheringPolicy = .gatherContinually
        result.candidateNetworkPolicy = .all
        result.disableIPV6 = true
        // don't send TCP candidates, they are passive and only server should be sending
        result.tcpCandidatePolicy = .disabled
        result.iceTransportPolicy = .all

        result.iceServers = [RTCIceServer(urlStrings: defaultIceServers)]

        return result
    }

    internal func update(iceServers: [Livekit_ICEServer]) {

        // convert to a list of RTCIceServer
        let rtcIceServers = iceServers.map { $0.toRTCType() }

        if !rtcIceServers.isEmpty {
            // set new iceServers if not empty
            self.iceServers = rtcIceServers
        }
    }
}
