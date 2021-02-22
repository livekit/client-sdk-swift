//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/30/20.
//

import Foundation
import WebRTC

public class RemoteDataTrack: DataTrack, RemoteTrack {
    public weak var delegate: RemoteDataTrackDelegate?
    public internal(set) var sid: Track.Sid
    
    init(sid: Track.Sid, rtcTrack: RTCDataChannel, name: String) {
        self.sid = sid
        super.init(rtcTrack: rtcTrack, name: name)
    }
}
