/*
 * Copyright 2022 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import WebRTC
import Promises

@objc
public class LocalAudioTrack: Track, LocalTrack, AudioTrack {

    internal init(name: String,
                  source: Track.Source,
                  track: RTCMediaStreamTrack) {

        super.init(name: name,
                   kind: .audio,
                   source: source,
                   track: track)
    }

    public static func createTrack(name: String = Track.microphoneName,
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
    internal override func onPublish() -> Promise<Bool> {
        super.onPublish().then(on: queue) { didPublish -> Bool in
            if didPublish {
                AudioManager.shared.trackDidStart(.local)
            }
            return didPublish
        }
    }

    @discardableResult
    internal override func onUnpublish() -> Promise<Bool> {
        super.onUnpublish().then(on: queue) { didUnpublish -> Bool in
            if didUnpublish {
                AudioManager.shared.trackDidStop(.local)
            }
            return didUnpublish
        }
    }
}

extension LocalAudioTrack {

    public var publishOptions: PublishOptions? { super._publishOptions }

    public var publishState: Track.PublishState { super._publishState }
}
