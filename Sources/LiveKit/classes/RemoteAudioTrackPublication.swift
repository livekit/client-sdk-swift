//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/15/20.
//

import Foundation

public class RemoteAudioTrackPublication: RemoteTrackPublication, AudioTrackPublication {
    public var audioTrack: AudioTrack? {
        get {
            return track as? AudioTrack
        }
    }
}
