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

import WebRTC
import Promises

class RemoteAudioTrack: RemoteTrack, AudioTrack {

    init(name: String,
         source: Track.Source,
         track: RTCMediaStreamTrack) {

        super.init(name: name,
                   kind: .audio,
                   source: source,
                   track: track)
    }

    @discardableResult
    override func start() -> Promise<Void> {
        super.start().then(on: .sdk) {
            AudioManager.shared.trackDidStart(.remote)
        }
    }

    @discardableResult
    override public func stop() -> Promise<Void> {
        super.stop().then(on: .sdk) {
            AudioManager.shared.trackDidStop(.remote)
        }
    }
}
