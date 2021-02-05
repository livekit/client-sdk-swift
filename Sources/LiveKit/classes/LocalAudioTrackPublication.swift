//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/10/20.
//

import Foundation

public class LocalAudioTrackPublication: LocalTrackPublication, AudioTrackPublication {
    public var audioTrack: AudioTrack? {
        track as? AudioTrack
    }
}
