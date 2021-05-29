//
//  LocalAudioTrack.swift
//
//
//  Created by Russell D'Sa on 11/7/20.
//

import Foundation
import WebRTC

public class LocalAudioTrack: AudioTrack {
    public static func createTrack(name: String, options opts: LocalAudioTrackOptions = LocalAudioTrackOptions()) -> LocalAudioTrack {
        let constraints: [String: String] = [
            "googEchoCancellation": boolToString(opts.echoCancellation),
            "googAutoGainControl": boolToString(opts.audoGainControl),
            "googNoiseSuppression": boolToString(opts.noiseSuppression),
            "googTypingNoiseDetection": boolToString(opts.typingNoiseDetection),
            "googHighpassFilter": boolToString(opts.highpassFilter),
            "googNoiseSuppression2": boolToString(opts.experimentalNoiseSuppression),
            "googAutoGainControl2": boolToString(opts.experimentalAutoGainControl)
        ]
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: constraints)

        let audioSource = RTCEngine.factory.audioSource(with: audioConstraints)
        let rtcTrack = RTCEngine.factory.audioTrack(with: audioSource, trackId: UUID().uuidString)
        rtcTrack.isEnabled = true
        return LocalAudioTrack(rtcTrack: rtcTrack, name: name)
    }
}

// placeholder so far
public struct LocalAudioTrackOptions {
    var noiseSuppression: Bool = true
    var echoCancellation: Bool = true
    var audoGainControl: Bool = true
    var typingNoiseDetection: Bool = false
    var highpassFilter: Bool = false
    var experimentalNoiseSuppression: Bool = false
    var experimentalAutoGainControl: Bool = false

    public init() {}
}

private func boolToString(_ val: Bool) -> String {
    if val {
        return "true"
    } else {
        return "false"
    }
}
