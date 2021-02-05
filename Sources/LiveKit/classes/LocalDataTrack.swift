//
//  LocalDataTrack.swift
//  
//
//  Created by Russell D'Sa on 12/30/20.
//

import Foundation
import WebRTC

public class LocalDataTrack: DataTrack {
    var options: DataTrackOptions
    var cid: Track.Cid = UUID().uuidString
    
    init(options: DataTrackOptions) {
        self.options = options
        super.init(name: options.name)
    }
    
    public func sendString(message: String) {
        guard let data = message.data(using: .utf8) else {
            print("local data track --- error sending message: \(message)")
            return
        }
        if let track = rtcTrack {
            track.sendData(RTCDataBuffer(data: data, isBinary: false))
        }
    }
    
    public func sendData(message: Data) {
        
        if let track = rtcTrack {
            track.sendData(RTCDataBuffer(data: message, isBinary: true))
        }
    }
    
    public static func track(options: DataTrackOptions) -> LocalDataTrack {
        return LocalDataTrack(options: options)
    }
}
