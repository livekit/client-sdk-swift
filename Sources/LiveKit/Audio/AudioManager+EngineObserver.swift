/*
 * Copyright 2025 LiveKit
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

import AVFAudio

/// Do not retain the engine object.
@objc
public protocol AudioEngineObserver: Chainable {
    @objc optional
    func engineDidCreate(_ engine: AVAudioEngine)

    @objc optional
    func engineWillEnable(_ engine: AVAudioEngine, playout: Bool, recording: Bool)

    @objc optional
    func engineWillStart(_ engine: AVAudioEngine, playout: Bool, recording: Bool)

    @objc optional
    func engineDidStop(_ engine: AVAudioEngine, playout: Bool, recording: Bool)

    @objc optional
    func engineDidDisable(_ engine: AVAudioEngine, playout: Bool, recording: Bool)

    @objc optional
    func engineWillRelease(_ engine: AVAudioEngine)

    @objc optional
    func engineWillConnectOutput(_ engine: AVAudioEngine, src: AVAudioNode, dst: AVAudioNode, format: AVAudioFormat)

    @objc optional
    func engineWillConnectInput(_ engine: AVAudioEngine, src: AVAudioNode, dst: AVAudioNode, format: AVAudioFormat)
}
