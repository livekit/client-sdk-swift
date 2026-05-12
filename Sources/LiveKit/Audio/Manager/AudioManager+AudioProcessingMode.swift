/*
 * Copyright 2026 LiveKit
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

internal import LiveKitWebRTC

public enum AudioProcessingMode: Sendable {
    /// Prefer Apple's system voice processing when available, otherwise use WebRTC software processing.
    case automatic
    /// Require Apple's system voice processing.
    case system
    /// Use WebRTC software processing and disable Apple's system voice processing.
    case software
    /// Disable both Apple's system voice processing and WebRTC software processing.
    case disabled
    case unknown
}

public enum AudioProcessingLifecycle: Sendable {
    case idle
    case running
    case transitioning
    case failed
    case unknown
}

public enum AudioProcessingBackend: Sendable {
    case disabled
    case system
    case software
    case unavailable
    case unknown
}

public struct AudioProcessingState: Sendable {
    public let requestedMode: AudioProcessingMode
    public let lifecycle: AudioProcessingLifecycle
    public let backend: AudioProcessingBackend
    public let transitionFrom: AudioProcessingMode
    public let transitionTo: AudioProcessingMode
    public let lastError: Int
    public let isSystemBypassed: Bool
    public let isSystemAGCEnabled: Bool
    public let isSoftwareEchoCancellationEnabled: Bool
    public let isSoftwareNoiseSuppressionEnabled: Bool
    public let isSoftwareAutoGainControlEnabled: Bool
    public let isSoftwareHighpassFilterEnabled: Bool
}

public extension AudioManager {
    var audioProcessingMode: AudioProcessingMode {
        RTC.audioDeviceModule.audioProcessingMode.toLKType()
    }

    var audioProcessingState: AudioProcessingState {
        RTC.audioDeviceModule.audioProcessingState.toLKType()
    }

    func setAudioProcessingMode(_ mode: AudioProcessingMode) throws {
        guard mode != .unknown else {
            throw LiveKitError(.invalidState, message: "Unsupported audio processing mode specified")
        }

        guard RTC.pcFactoryState.admType == .audioEngine else {
            throw LiveKitError(.invalidState, message: "Audio processing mode is only supported by the audioEngine audio device module")
        }

        let result = RTC.audioDeviceModule.setAudioProcessingMode(mode.toRTCType())
        try checkAdmResult(code: result)
    }
}

// MARK: - Internal

extension LKRTCAudioProcessingMode {
    func toLKType() -> AudioProcessingMode {
        switch self {
        case .automatic: return .automatic
        case .system: return .system
        case .software: return .software
        case .disabled: return .disabled
        @unknown default: return .unknown
        }
    }
}

extension AudioProcessingMode {
    func toRTCType() -> LKRTCAudioProcessingMode {
        switch self {
        case .automatic: .automatic
        case .system: .system
        case .software: .software
        case .disabled: .disabled
        case .unknown: .automatic
        }
    }
}

extension LKRTCAudioProcessingLifecycle {
    func toLKType() -> AudioProcessingLifecycle {
        switch self {
        case .idle: return .idle
        case .running: return .running
        case .transitioning: return .transitioning
        case .failed: return .failed
        @unknown default: return .unknown
        }
    }
}

extension LKRTCAudioProcessingBackend {
    func toLKType() -> AudioProcessingBackend {
        switch self {
        case .disabled: return .disabled
        case .system: return .system
        case .software: return .software
        case .unavailable: return .unavailable
        @unknown default: return .unknown
        }
    }
}

extension LKRTCAudioProcessingState {
    func toLKType() -> AudioProcessingState {
        AudioProcessingState(
            requestedMode: requestedMode.toLKType(),
            lifecycle: lifecycle.toLKType(),
            backend: backend.toLKType(),
            transitionFrom: transitionFrom.toLKType(),
            transitionTo: transitionTo.toLKType(),
            lastError: lastError,
            isSystemBypassed: systemBypassed,
            isSystemAGCEnabled: systemAGCEnabled,
            isSoftwareEchoCancellationEnabled: softwareEchoCancellation,
            isSoftwareNoiseSuppressionEnabled: softwareNoiseSuppression,
            isSoftwareAutoGainControlEnabled: softwareAutoGainControl,
            isSoftwareHighpassFilterEnabled: softwareHighpassFilter
        )
    }
}
