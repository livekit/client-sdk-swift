import Foundation
import WebRTC
import Promises

public class LocalAudioTrack: LocalTrack, AudioTrack {

    internal init(name: String,
                  source: Track.Source,
                  track: RTCMediaStreamTrack) {

        super.init(name: name,
                   kind: .audio,
                   source: source,
                   track: track)
    }

    public static func createTrack(name: String,
                                   options: AudioCaptureOptions? = nil) -> LocalAudioTrack {

        let options = options ?? AudioCaptureOptions()

        let constraints: [String: String] = [
            "googEchoCancellation": options.echoCancellation.toString(),
            "googAutoGainControl": options.autoGainControl.toString(),
            "googNoiseSuppression": options.noiseSuppression.toString(),
            "googTypingNoiseDetection": options.typingNoiseDetection.toString(),
            "googHighpassFilter": options.highpassFilter.toString(),
            "googNoiseSuppression2": options.experimentalNoiseSuppression.toString(),
            "googAutoGainControl2": options.experimentalAutoGainControl.toString()
        ]

        let audioConstraints = DispatchQueue.webRTC.sync { RTCMediaConstraints(mandatoryConstraints: nil,
                                                                               optionalConstraints: constraints) }

        let audioSource = Engine.createAudioSource(audioConstraints)
        let rtcTrack = Engine.createAudioTrack(source: audioSource)
        rtcTrack.isEnabled = true

        return LocalAudioTrack(name: name,
                               source: .microphone,
                               track: rtcTrack)
    }

    @discardableResult
    override func start() -> Promise<Void> {
        super.start().then {
            AudioManager.shared.trackDidStart(.local)
        }
    }

    @discardableResult
    override public func stop() -> Promise<Void> {
        super.stop().then {
            AudioManager.shared.trackDidStop(.local)
        }
    }
}
