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

import Promises

public class LocalTrack: Track {

    public enum PublishState {
        case unpublished
        case published
    }

    public private(set) var publishState: PublishState = .unpublished

    /// ``publishOptions`` used for this track if already published.
    public internal(set) var publishOptions: PublishOptions?

    public func mute() -> Promise<Void> {
        // Already muted
        if muted { return Promise(()) }

        return disable().then(on: .sdk) { _ in
            self.stop()
        }.then(on: .sdk) { _ -> Void in
            self.set(muted: true, shouldSendSignal: true)
        }
    }

    public func unmute() -> Promise<Void> {
        // Already un-muted
        if !muted { return Promise(()) }

        return enable().then(on: .sdk) { _ in
            self.start()
        }.then(on: .sdk) { _ -> Void in
            self.set(muted: false, shouldSendSignal: true)
        }
    }

    // returns true if state updated
    internal func onPublish() -> Promise<Bool> {

        Promise<Bool>(on: .sdk) { [weak self] () -> Bool in

            guard let self = self, self.publishState != .published else {
                // already published
                return false
            }

            self.publishState = .published
            return true
        }
    }

    // returns true if state updated
    internal func onUnpublish() -> Promise<Bool> {

        Promise<Bool>(on: .sdk) { [weak self] () -> Bool in

            guard let self = self, self.publishState != .unpublished else {
                // already unpublished
                return false
            }

            self.publishState = .unpublished
            return true
        }
    }
}
