//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/29/20.
//

import Foundation

public class RemoteTrackPublication: TrackPublication {
    
    public var remoteTrack: Track? {
        get {
            return track
        }
    }
    
    public var trackSubscribed: Bool {
        get {
            return track != nil
        }
    }
    
//    public private(set) publishPriority: TrackPriority
}
