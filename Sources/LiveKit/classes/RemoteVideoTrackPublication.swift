//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/29/20.
//

import Foundation

public class RemoteVideoTrackPublication: RemoteTrackPublication {
    public var videoTrack: VideoTrack? {
        get {
            return track as? VideoTrack
        }
    }
}
