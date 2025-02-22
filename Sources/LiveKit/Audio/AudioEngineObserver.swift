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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

public let AudioEngineInputMixerNodeKey = kRTCAudioEngineInputMixerNodeKey

/// Do not retain the engine object.
public protocol AudioEngineObserver: NextInvokable, Sendable {
    associatedtype Next = any AudioEngineObserver
    var next: (any AudioEngineObserver)? { get set }

    func engineDidCreate(_ engine: AVAudioEngine)
    func engineWillEnable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool)
    func engineWillStart(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool)
    func engineDidStop(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool)
    func engineDidDisable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool)
    func engineWillRelease(_ engine: AVAudioEngine)

    /// Provide custom implementation for internal AVAudioEngine's output configuration.
    /// Buffers flow from `src` to `dst`. Preferred format to connect node is provided as `format`.
    /// Return true if custom implementation is provided, otherwise default implementation will be used.
    func engineWillConnectOutput(_ engine: AVAudioEngine, src: AVAudioNode, dst: AVAudioNode?, format: AVAudioFormat, context: [AnyHashable: Any])
    /// Provide custom implementation for internal AVAudioEngine's input configuration.
    /// Buffers flow from `src` to `dst`. Preferred format to connect node is provided as `format`.
    /// Return true if custom implementation is provided, otherwise default implementation will be used.
    func engineWillConnectInput(_ engine: AVAudioEngine, src: AVAudioNode?, dst: AVAudioNode, format: AVAudioFormat, context: [AnyHashable: Any])
}

/// Default implementation to make it optional.
public extension AudioEngineObserver {
    func engineDidCreate(_ engine: AVAudioEngine) {
        next?.engineDidCreate(engine)
    }

    func engineWillEnable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) {
        next?.engineWillEnable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
    }

    func engineWillStart(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) {
        next?.engineWillStart(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
    }

    func engineDidStop(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) {
        next?.engineDidStop(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
    }

    func engineDidDisable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) {
        next?.engineDidDisable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
    }

    func engineWillRelease(_ engine: AVAudioEngine) {
        next?.engineWillRelease(engine)
    }

    func engineWillConnectOutput(_ engine: AVAudioEngine, src: AVAudioNode, dst: AVAudioNode?, format: AVAudioFormat, context: [AnyHashable: Any]) {
        next?.engineWillConnectOutput(engine, src: src, dst: dst, format: format, context: context)
    }

    func engineWillConnectInput(_ engine: AVAudioEngine, src: AVAudioNode?, dst: AVAudioNode, format: AVAudioFormat, context: [AnyHashable: Any]) {
        next?.engineWillConnectInput(engine, src: src, dst: dst, format: format, context: context)
    }
}
