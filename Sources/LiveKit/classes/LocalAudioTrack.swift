//
//  LocalAudioTrack.swift
//
//
//  Created by Russell D'Sa on 11/7/20.
//

import Foundation
import WebRTC

public class LocalAudioTrack: AudioTrack {
    public static func createTrack(name: String, options _: LocalAudioTrackOptions = LocalAudioTrackOptions()) -> LocalAudioTrack {
        let audioSource = RTCEngine.factory.audioSource(with: RTCEngine.mediaConstraints)
        let rtcTrack = RTCEngine.factory.audioTrack(with: audioSource, trackId: UUID().uuidString)
        rtcTrack.isEnabled = true
        return LocalAudioTrack(rtcTrack: rtcTrack, name: name)
    }
}

// placeholder so far
public struct LocalAudioTrackOptions {
    public init() {}
}
