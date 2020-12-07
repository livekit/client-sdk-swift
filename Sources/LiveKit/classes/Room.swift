//
//  File.swift
//  
//
//  Created by Russell D'Sa on 11/7/20.
//

import Foundation
import WebRTC

class Room {
    private var client: RTCClient
    private var engine: RTCEngine
    var sid: String
    
    init(name: String) {
        sid = name
        client = RTCClient()
        engine = RTCEngine(client: client)
    }
    
    func connect(options: ConnectOptions) {
        engine.join(options: options)
    }
}
