import Foundation
import WebRTC

public class LocalAudioTrack: AudioTrack {

    public static func createTrack(name: String, options opts: LocalAudioTrackOptions = LocalAudioTrackOptions()) -> LocalAudioTrack {
        let constraints: [String: String] = [
            "googEchoCancellation": opts.echoCancellation.toString(),
            "googAutoGainControl": opts.audoGainControl.toString(),
            "googNoiseSuppression": opts.noiseSuppression.toString(),
            "googTypingNoiseDetection": opts.typingNoiseDetection.toString(),
            "googHighpassFilter": opts.highpassFilter.toString(),
            "googNoiseSuppression2": opts.experimentalNoiseSuppression.toString(),
            "googAutoGainControl2": opts.experimentalAutoGainControl.toString()
        ]
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: constraints)

        let audioSource = Engine.factory.audioSource(with: audioConstraints)
        let rtcTrack = Engine.factory.audioTrack(with: audioSource, trackId: UUID().uuidString)
        rtcTrack.isEnabled = true
        return LocalAudioTrack(rtcTrack: rtcTrack, name: name)
    }

    override func start() {
        super.start()
        //
    }

    override func stop() {
        super.stop()
        //
    }
}
