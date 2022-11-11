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
public class RemoteAudioTrack: Track, RemoteTrack, AudioTrack {

    /// Volume with range 0.0 - 1.0
    public var volume: Double {
        get {
            guard let audioTrack = mediaTrack as? RTCAudioTrack else { return 0 }
            return audioTrack.source.volume / 10
        }
        set {
            guard let audioTrack = mediaTrack as? RTCAudioTrack else { return }
            audioTrack.source.volume = newValue * 10
        }
    }

    init(name: String,
         source: Track.Source,
         track: RTCMediaStreamTrack) {

        super.init(name: name,
                   kind: .audio,
                   source: source,
                   track: track)
    }

    override public func start() -> Promise<Bool> {
        super.start().then(on: queue) { didStart -> Bool in
            if didStart {
                AudioManager.shared.trackDidStart(.remote)
            }
            return didStart
        }
    }

    override public func stop() -> Promise<Bool> {
        super.stop().then(on: queue) { didStop -> Bool in
            if didStop {
                AudioManager.shared.trackDidStop(.remote)
            }
            return didStop
        }
    }
}
