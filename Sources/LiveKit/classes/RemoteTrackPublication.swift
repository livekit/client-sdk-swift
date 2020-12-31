//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/29/20.
//

import Foundation

public class RemoteTrackPublication: TrackPublication {
    
    public var remoteTrack: Track? { track }
    public var trackSubscribed: Bool { track != nil }
    public private(set) var publishPriority: Track.Priority = .standard
}
