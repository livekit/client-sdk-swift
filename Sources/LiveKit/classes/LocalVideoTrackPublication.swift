//
//  File 2.swift
//  
//
//  Created by Russell D'Sa on 12/10/20.
//

import Foundation

public class LocalVideoTrackPublication: LocalTrackPublication, VideoTrackPublication {
    public var videoTrack: VideoTrack? { track as? VideoTrack }
}
