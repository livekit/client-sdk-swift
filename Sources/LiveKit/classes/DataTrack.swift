//
//  File.swift
//
//
//  Created by Russell D'Sa on 12/30/20.
//

import Foundation
import WebRTC

public class DataTrack: Track {
    var dataChannel: RTCDataChannel?

    public var ordered: Bool? { dataChannel?.isOrdered }

    public var maxPacketLifeTime: UInt16? { dataChannel?.maxPacketLifeTime }

    public var maxRetransmits: UInt16? { dataChannel?.maxRetransmits }

    init(name: String, dataChannel: RTCDataChannel?) {
//        var state: Track.State = .none
//
//        if let t = rtcTrack {
//            state = try! Track.stateFromRTCDataChannelState(rtcState: t.readyState)
//        }
        self.dataChannel = dataChannel
        super.init(name: name, kind: .data)
    }
}
