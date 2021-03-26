//
//  LocalAudioTrack.swift
//  
//
//  Created by Russell D'Sa on 11/7/20.
//

import Foundation
import WebRTC

public class LocalAudioTrack: AudioTrack {
     public private(set) var options: AudioOptions?
    
    private init(rtcTrack: RTCAudioTrack, options: AudioOptions? = nil, name: String) {
        self.options = options
        super.init(rtcTrack: rtcTrack, name: name)
    }
    
    public static func track(name: String) -> LocalAudioTrack {
        let audioSource = RTCEngine.factory.audioSource(with: RTCEngine.mediaConstraints)
        let rtcTrack = RTCEngine.factory.audioTrack(with: audioSource, trackId: UUID().uuidString)
        rtcTrack.isEnabled = true
        return LocalAudioTrack(rtcTrack: rtcTrack, name: name)
    }
    
    public static func track(options: AudioOptions, enabled: Bool, name: String) -> LocalAudioTrack {
        let audioSource = RTCEngine.factory.audioSource(with: RTCEngine.mediaConstraints)
        let rtcTrack = RTCEngine.factory.audioTrack(with: audioSource, trackId: UUID().uuidString)
        rtcTrack.isEnabled = enabled
        return LocalAudioTrack(rtcTrack: rtcTrack, options: options, name: name)
    }
}
