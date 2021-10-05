//
//  File.swift
//  
//
//  Created by Hiroshi Horie on 2021/10/06.
//

import WebRTC

extension RTCConfiguration {

    static func liveKitDefault() -> RTCConfiguration {

        let result = RTCConfiguration()
        result.sdpSemantics = .unifiedPlan
        result.continualGatheringPolicy = .gatherContinually
        result.candidateNetworkPolicy = .all
        result.disableIPV6 = true
        // don't send TCP candidates, they are passive and only server should be sending
        result.tcpCandidatePolicy = .disabled
        result.iceTransportPolicy = .all

        return result
    }
}
