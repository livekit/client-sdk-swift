import Foundation
import WebRTC

public class LocalAudioTrack: AudioTrack {

    public static func createTrack(name: String,
                                   options: LocalAudioTrackOptions = LocalAudioTrackOptions()) -> LocalAudioTrack {

        let constraints: [String: String] = [
            "googEchoCancellation": options.echoCancellation.toString(),
            "googAutoGainControl": options.autoGainControl.toString(),
            "googNoiseSuppression": options.noiseSuppression.toString(),
            "googTypingNoiseDetection": options.typingNoiseDetection.toString(),
            "googHighpassFilter": options.highpassFilter.toString(),
            "googNoiseSuppression2": options.experimentalNoiseSuppression.toString(),
            "googAutoGainControl2": options.experimentalAutoGainControl.toString()
        ]
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: constraints)

        let audioSource = Engine.factory.audioSource(with: audioConstraints)
        let rtcTrack = Engine.factory.audioTrack(with: audioSource, trackId: UUID().uuidString)
        rtcTrack.isEnabled = true
        return LocalAudioTrack(rtcTrack: rtcTrack, name: name, source: .microphone)
    }
}
