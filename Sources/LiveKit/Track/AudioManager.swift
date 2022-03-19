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

// Audio Session Configuration related
public class AudioManager: Loggable {

    public enum State {
        case none
        case localOnly
        case remoteOnly
        case localAndRemote
    }

    internal enum `Type` {
        case local
        case remote
    }

    public static let shared = AudioManager()

    public private(set) var state: State = .none {
        didSet {
            guard oldValue != state else { return }
            log("AudioManager.state didUpdate \(oldValue) -> \(state)")
            #if os(iOS)
            LiveKit.onShouldConfigureAudioSession(state, oldValue)
            #endif
        }
    }

    public private(set) var localTracksCount = 0 {
        didSet { recomputeState() }
    }

    public private(set) var remoteTracksCount = 0 {
        didSet { recomputeState() }
    }

    // Singleton
    private init() {}

    internal func trackDidStart(_ type: Type) {
        if type == .local { localTracksCount += 1 }
        if type == .remote { remoteTracksCount += 1 }
    }

    internal func trackDidStop(_ type: Type) {
        if type == .local { localTracksCount -= 1 }
        if type == .remote { remoteTracksCount -= 1 }

    }

    private func recomputeState() {
        if localTracksCount > 0 && remoteTracksCount == 0 {
            state = .localOnly
        } else if localTracksCount == 0 && remoteTracksCount > 0 {
            state = .remoteOnly
        } else if localTracksCount > 0 && remoteTracksCount > 0 {
            state = .localAndRemote
        } else {
            state = .none
        }
    }
}
