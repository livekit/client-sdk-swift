//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/4/20.
//

import Foundation
import WebRTC

struct RTCEngine {
//    private var peerConnection: RTCPeerConnection
    var client: RTCClient
    
//    private static let factory: RTCPeerConnectionFactory = {
//        RTCInitializeSSL()
//        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
//        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
//        return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
//    }()
    
    init(client: RTCClient) {
        self.client = client
        
//        let config = RTCConfiguration()
//        config.iceServers = [RTCIceServer(urlStrings: iceServers)]
//        // Unified plan is more superior than planB
//        config.sdpSemantics = .unifiedPlan
//        // gatherContinually will let WebRTC to listen to any network changes and send any new candidates to the other client
//        config.continualGatheringPolicy = .gatherContinually
//
//        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
//                                              optionalConstraints: ["DtlsSrtpKeyAgreement":kRTCMediaConstraintsValueTrue])
//        peerConnection = RTCEngine.factory.peerConnection(with: config, constraints: constraints, delegate: <#T##RTCPeerConnectionDelegate?#>)
    }
    
    func join(options: ConnectOptions) {
        
    }
}
