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

public class AudioEngineState: CustomDebugStringConvertible {
    private let rtcState: LKRTCAudioEngineState

    public var isOutputEnabled: Bool { rtcState.isOutputEnabled }
    public var isOutputRunning: Bool { rtcState.isOutputRunning }
    public var isInputEnabled: Bool { rtcState.isInputEnabled }
    public var isInputRunning: Bool { rtcState.isInputRunning }
    public var isInputMuted: Bool { rtcState.isInputMuted }
    public var isLegacyMuteMode: Bool { rtcState.muteMode == .restartEngine }

    init(fromRTCType rtcState: LKRTCAudioEngineState) {
        self.rtcState = rtcState
    }

    public var debugDescription: String {
        "AudioEngineState(isOutputEnabled: \(isOutputEnabled), isOutputRunning: \(isOutputRunning), isInputEnabled: \(isInputEnabled), isInputRunning: \(isInputRunning), isInputMuted: \(isInputMuted), isLegacyMuteMode: \(isLegacyMuteMode))"
    }
}

public class AudioEngineStateTransition: CustomDebugStringConvertible {
    private let rtcStateTransition: LKRTCAudioEngineStateTransition

    public var prev: AudioEngineState { AudioEngineState(fromRTCType: rtcStateTransition.prev) }
    public var next: AudioEngineState { AudioEngineState(fromRTCType: rtcStateTransition.next) }

    init(fromRTCType rtcStateTransition: LKRTCAudioEngineStateTransition) {
        self.rtcStateTransition = rtcStateTransition
    }

    public var debugDescription: String {
        "AudioEngineStateTransition(prev: \(prev), next: \(next))"
    }
}

// Invoked on WebRTC's worker thread, do not block.
class AudioDeviceModuleDelegateAdapter: NSObject, LKRTCAudioDeviceModuleDelegate {
    weak var audioManager: AudioManager?

    func audioDeviceModule(_: LKRTCAudioDeviceModule, didReceiveMutedSpeechActivityEvent speechActivityEvent: RTCSpeechActivityEvent) {
        guard let audioManager else { return }
        audioManager._state.onMutedSpeechActivity?(audioManager, speechActivityEvent.toLKType())
    }

    func audioDeviceModuleDidUpdateDevices(_: LKRTCAudioDeviceModule) {
        guard let audioManager else { return }
        audioManager._state.onDevicesDidUpdate?(audioManager)
    }

    // Engine events

    func audioDeviceModule(_: LKRTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine, stateTransition: LKRTCAudioEngineStateTransition) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineDidCreate(engine, state: AudioEngineStateTransition(fromRTCType: stateTransition)) ?? 0
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine, stateTransition: LKRTCAudioEngineStateTransition) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineWillEnable(engine, state: AudioEngineStateTransition(fromRTCType: stateTransition)) ?? 0
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, willStartEngine engine: AVAudioEngine, stateTransition: LKRTCAudioEngineStateTransition) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineWillStart(engine, state: AudioEngineStateTransition(fromRTCType: stateTransition)) ?? 0
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, didStopEngine engine: AVAudioEngine, stateTransition: LKRTCAudioEngineStateTransition) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineDidStop(engine, state: AudioEngineStateTransition(fromRTCType: stateTransition)) ?? 0
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine, stateTransition: LKRTCAudioEngineStateTransition) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineDidDisable(engine, state: AudioEngineStateTransition(fromRTCType: stateTransition)) ?? 0
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine, stateTransition: LKRTCAudioEngineStateTransition) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineWillRelease(engine, state: AudioEngineStateTransition(fromRTCType: stateTransition)) ?? 0
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, engine: AVAudioEngine, configureInputFromSource src: AVAudioNode?, toDestination dst: AVAudioNode, format: AVAudioFormat, stateTransition: LKRTCAudioEngineStateTransition, context: [AnyHashable: Any]) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineWillConnectInput(engine,
                                                  src: src,
                                                  dst: dst,
                                                  format: format,
                                                  state: AudioEngineStateTransition(fromRTCType: stateTransition),
                                                  context: context) ?? 0
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, engine: AVAudioEngine, configureOutputFromSource src: AVAudioNode, toDestination dst: AVAudioNode?, format: AVAudioFormat, stateTransition: LKRTCAudioEngineStateTransition, context: [AnyHashable: Any]) -> Int {
        guard let audioManager else { return 0 }
        let entryPoint = audioManager.buildEngineObserverChain()
        return entryPoint?.engineWillConnectOutput(engine,
                                                   src: src,
                                                   dst: dst,
                                                   format: format,
                                                   state: AudioEngineStateTransition(fromRTCType: stateTransition),
                                                   context: context) ?? 0
    }
}
