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

internal import LiveKitWebRTC

// Invoked on WebRTC's worker thread, do not block.
class AudioDeviceModuleDelegateAdapter: NSObject, LKRTCAudioDeviceModuleDelegate, Loggable {
    weak var audioManager: AudioManager?

    func audioDeviceModule(_: LKRTCAudioDeviceModule, didReceiveSpeechActivityEvent speechActivityEvent: LKRTCSpeechActivityEvent) {
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
        let result = entryPoint?.engineWillEnable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0

        // At this point mic perms / session should be configured for recording.
        if result == 0, isRecordingEnabled {
            // This will block WebRTC's worker thread, but when instantiating AVAudioInput node it will block by showing a dialog anyways.
            // Attempt to acquire mic perms at this point to return an error at SDK level.
            let isAuthorized = LiveKitSDK.ensureDeviceAccessSync(for: [.audio])
            log("AudioEngine pre-enable check, device permission: \(isAuthorized)")
            if !isAuthorized {
                return kAudioEngineErrorInsufficientDevicePermission
            }

            #if os(iOS) || os(visionOS) || os(tvOS)
            // Additional check for audio session category.
            let session = LKRTCAudioSession.sharedInstance()
            log("AudioEngine pre-enable check, audio session: \(session.category)")
            if ![AVAudioSession.Category.playAndRecord.rawValue,
                 AVAudioSession.Category.record.rawValue].contains(session.category)
            {
                return kAudioEngineErrorAudioSessionCategoryRecordingRequired
            }
            #endif
        }

        return result
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
