//
//  File.swift
//  
//
//  Created by Russell D'Sa on 1/31/21.
//

import Foundation

public class LocalTrackPublication: TrackPublication {
    public var localTrack: Track? { track }
    public private(set) var priority: Track.Priority = .standard
}
