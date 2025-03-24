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

import Foundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

// Invoked on WebRTC's worker thread, do not block.
class AudioDeviceModuleDelegateAdapter: NSObject, LKRTCAudioDeviceModuleDelegate {
    weak var audioManager: AudioManager?

    func audioDeviceModule(_: LKRTCAudioDeviceModule, didReceiveSpeechActivityEvent speechActivityEvent: RTCSpeechActivityEvent) {
        guard let audioManager else { return }
        audioManager._state.onMutedSpeechActivity?(audioManager, speechActivityEvent.toLKType())
    }

    func audioDeviceModuleDidUpdateDevices(_: LKRTCAudioDeviceModule) {
        guard let audioManager else { return }
        audioManager._state.onDevicesDidUpdate?(audioManager)
    }

    // Engine events

    func audioDeviceModule(_: LKRTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineDidCreate(engine) ?? 0
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineWillEnable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, willStartEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineWillStart(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, didStopEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineDidStop(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineDidDisable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineWillRelease(engine) ?? 0
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, engine: AVAudioEngine, configureInputFromSource src: AVAudioNode?, toDestination dst: AVAudioNode, format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineWillConnectInput(engine, src: src, dst: dst, format: format, context: context) ?? 0
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, engine: AVAudioEngine, configureOutputFromSource src: AVAudioNode, toDestination dst: AVAudioNode?, format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineWillConnectOutput(engine, src: src, dst: dst, format: format, context: context) ?? 0
    }
}
