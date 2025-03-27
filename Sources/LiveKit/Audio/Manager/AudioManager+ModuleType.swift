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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

public enum AudioDeviceModuleType {
    /// Use AVAudioEngine-based AudioDeviceModule internally which will be used for all platforms.
    case audioEngine
    /// Use WebRTC's default AudioDeviceModule internally, which uses AudioUnit for iOS, HAL APIs for macOS.
    case platformDefault
}

extension AudioDeviceModuleType {
    func toRTCType() -> RTCAudioDeviceModuleType {
        switch self {
        case .audioEngine: .audioEngine
        case .platformDefault: .platformDefault
        }
    }
}

public extension AudioManager {
    /// Sets the desired `AudioDeviceModuleType` to be used which handles all audio input / output.
    ///
    /// This method must be called before the peer connection is initialized. Changing the module type after
    /// initialization is not supported and will result in an error.
    func set(audioDeviceModuleType: AudioDeviceModuleType) throws {
        // Throw if pc factory is already initialized.
        guard !_pcState.isInitialized else {
            throw LiveKitError(.invalidState, message: "Cannot set this property after the peer connection has been initialized")
        }
        _pcState.mutate { $0.admType = audioDeviceModuleType }
    }
}

// MARK: - Internal

struct PeerConnectionFactoryState {
    var isInitialized: Bool = false
    var admType: AudioDeviceModuleType = .audioEngine
}

let _pcState = StateSync(PeerConnectionFactoryState())
