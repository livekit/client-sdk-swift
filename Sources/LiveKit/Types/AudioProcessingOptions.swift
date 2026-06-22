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

import Foundation

internal import LiveKitWebRTC

@objc
public enum AudioProcessingMode: Int, CaseIterable, Hashable, Sendable {
    /// Prefer platform voice processing when available and fall back to WebRTC software processing.
    case automatic
    /// Use platform voice processing only. If platform processing is unavailable, the request is rejected.
    case platform
    /// Force WebRTC software processing and disable the matching platform effect when possible.
    case software
}

public enum AudioProcessingOptionsResultCode: Int, Sendable {
    /// Options were applied immediately by the component handling the request.
    case applied
    /// Options were accepted and stored. Active senders reapply them separately.
    case stored
    case rejectedRemoteTrack
    case rejectedInvalidCombination
    case rejectedPlatformUnavailable
    case applyFailed
}

public enum AudioProcessingImplementation: Int, Sendable {
    case unknown
    case disabled
    case software
    case platform
    case softwareAndPlatform
}

public struct AudioProcessingOptionsResult: Sendable {
    public let code: AudioProcessingOptionsResultCode
    public let message: String

    public var isSuccess: Bool {
        code == .applied || code == .stored
    }
}

@objcMembers
public final class AudioProcessingOptions: NSObject, Sendable {
    public static let communication = AudioProcessingOptions()

    public static let noProcessing = AudioProcessingOptions(
        echoCancellation: false,
        autoGainControl: false,
        noiseSuppression: false,
        highPassFilter: false,
    )

    public let echoCancellation: Bool
    public let autoGainControl: Bool
    public let noiseSuppression: Bool
    public let highPassFilter: Bool

    public let echoCancellationMode: AudioProcessingMode
    public let autoGainControlMode: AudioProcessingMode
    public let noiseSuppressionMode: AudioProcessingMode
    public let highPassFilterMode: AudioProcessingMode

    public init(
        echoCancellation: Bool = true,
        autoGainControl: Bool = true,
        noiseSuppression: Bool = true,
        highPassFilter: Bool = false,
        echoCancellationMode: AudioProcessingMode = .automatic,
        autoGainControlMode: AudioProcessingMode = .automatic,
        noiseSuppressionMode: AudioProcessingMode = .automatic,
        highPassFilterMode: AudioProcessingMode = .automatic,
    ) {
        self.echoCancellation = echoCancellation
        self.autoGainControl = autoGainControl
        self.noiseSuppression = noiseSuppression
        self.highPassFilter = highPassFilter
        self.echoCancellationMode = echoCancellationMode
        self.autoGainControlMode = autoGainControlMode
        self.noiseSuppressionMode = noiseSuppressionMode
        self.highPassFilterMode = highPassFilterMode
    }

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return echoCancellation == other.echoCancellation &&
            autoGainControl == other.autoGainControl &&
            noiseSuppression == other.noiseSuppression &&
            highPassFilter == other.highPassFilter &&
            echoCancellationMode == other.echoCancellationMode &&
            autoGainControlMode == other.autoGainControlMode &&
            noiseSuppressionMode == other.noiseSuppressionMode &&
            highPassFilterMode == other.highPassFilterMode
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(echoCancellation)
        hasher.combine(autoGainControl)
        hasher.combine(noiseSuppression)
        hasher.combine(highPassFilter)
        hasher.combine(echoCancellationMode)
        hasher.combine(autoGainControlMode)
        hasher.combine(noiseSuppressionMode)
        hasher.combine(highPassFilterMode)
        return hasher.finalize()
    }
}

/// The caller's request for one audio processing component: enabled flag plus
/// implementation mode.
public struct AudioProcessingComponentRequest: Sendable {
    public let isEnabled: Bool
    public let mode: AudioProcessingMode
}

/// Diagnostic state of one audio processing component (echo cancellation,
/// noise suppression, auto gain control or high-pass filter), observed at
/// three stages of one pipeline: requested (caller intent) -> resolved (the
/// engine's per-path decision) -> active (live truth), with ``effective`` as
/// the merged verdict.
public struct AudioProcessingComponentState: Sendable {
    /// What the caller most recently requested for this component. `nil` when
    /// no audio processing options have ever been applied — "nobody asked".
    public let requested: AudioProcessingComponentRequest?

    /// Whether the resolver decided the WebRTC software (APM) implementation
    /// should run, after weighing the requested mode against platform
    /// availability, coupling, and policy.
    public let isSoftwareResolved: Bool

    /// Whether APM's live configuration currently has this component enabled.
    public let isSoftwareActive: Bool

    /// Whether this device/OS offers a built-in implementation at all.
    public let isPlatformAvailable: Bool

    /// Whether the engine asked the OS to run the platform implementation.
    /// The OS owns the outcome: it can decline, defer, or couple components.
    public let isPlatformResolved: Bool

    /// Whether the device reports the platform implementation actually running.
    public let isPlatformActive: Bool

    /// The verdict: which implementation is in effect right now.
    public let effective: AudioProcessingImplementation
}

/// Diagnostic snapshot of the resolved audio processing state for the shared
/// audio processing module.
///
/// The module is owned by the peer connection factory and shared engine-wide,
/// so this reflects what is actually applied (per-component
/// ``AudioProcessingComponentState/effective``) versus what was requested —
/// for the whole engine, not a single track. Device-level platform processing
/// detail lives on ``PlatformAudioProcessingState`` instead.
public struct AudioProcessingState: Sendable {
    public let hasAudioProcessingModule: Bool
    public let echoCancellation: AudioProcessingComponentState
    public let noiseSuppression: AudioProcessingComponentState
    public let autoGainControl: AudioProcessingComponentState
    public let highPassFilter: AudioProcessingComponentState
}

public enum PlatformAudioProcessingTopology: Int, Sendable {
    case independent
    case echoCancellationAndNoiseSuppressionCoupled
}

public struct PlatformAudioProcessingComponentState: Sendable {
    /// Whether the device offers this effect at all.
    public let isAvailable: Bool
    /// The last state requested from the audio device module.
    public let isRequested: Bool
    /// Live OS readback when the audio device module can query the effect.
    public let isActive: Bool
}

/// Device-level snapshot of platform audio processing.
///
/// The `isVoiceProcessing*` properties reflect the Apple Voice Processing I/O
/// unit: requested values are the state stored by the audio device module;
/// active values are live readback from the platform input node and read
/// `false` before input is configured or where the value is not observable.
public struct PlatformAudioProcessingState: Sendable {
    public let topology: PlatformAudioProcessingTopology
    public let echoCancellation: PlatformAudioProcessingComponentState
    public let noiseSuppression: PlatformAudioProcessingComponentState
    public let autoGainControl: PlatformAudioProcessingComponentState
    public let isVoiceProcessingEnabledRequested: Bool
    public let isVoiceProcessingBypassedRequested: Bool
    public let isVoiceProcessingAGCEnabledRequested: Bool
    public let isVoiceProcessingEnabledActive: Bool
    public let isVoiceProcessingBypassedActive: Bool
    public let isVoiceProcessingAGCEnabledActive: Bool
}

extension AudioProcessingMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .automatic: "Automatic"
        case .platform: "Platform"
        case .software: "Software"
        }
    }
}

extension AudioProcessingImplementation: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknown: "Unknown"
        case .disabled: "Disabled"
        case .software: "Software"
        case .platform: "Platform"
        case .softwareAndPlatform: "Software + Platform"
        }
    }
}

extension AudioProcessingMode {
    func toRTCType() -> LKRTCAudioProcessingMode {
        switch self {
        case .automatic: .automatic
        case .platform: .platform
        case .software: .software
        }
    }

    func toConstraintValue() -> String {
        switch self {
        case .automatic: "auto"
        case .platform: "platform"
        case .software: "software"
        }
    }
}

extension LKRTCAudioProcessingMode {
    func toLKType() -> AudioProcessingMode {
        switch self {
        case .automatic: .automatic
        case .platform: .platform
        case .software: .software
        @unknown default: .automatic
        }
    }
}

extension LKRTCAudioProcessingImplementation {
    func toLKType() -> AudioProcessingImplementation {
        switch self {
        case .unknown: .unknown
        case .disabled: .disabled
        case .software: .software
        case .platform: .platform
        case .softwareAndPlatform: .softwareAndPlatform
        @unknown default: .unknown
        }
    }
}

extension AudioProcessingOptionsResultCode {
    init(_ code: LKRTCAudioProcessingOptionsResultCode) {
        self = Self(rawValue: code.rawValue) ?? .applyFailed
    }
}

extension LKRTCAudioProcessingOptionsResult {
    func toLKType() -> AudioProcessingOptionsResult {
        AudioProcessingOptionsResult(
            code: AudioProcessingOptionsResultCode(code),
            message: message,
        )
    }
}

extension AudioProcessingOptions {
    func toRTCType() -> LKRTCAudioProcessingOptions {
        LKRTCAudioProcessingOptions(
            echoCancellationOptions: LKRTCAudioProcessingComponentOptions(
                enabled: echoCancellation,
                mode: echoCancellationMode.toRTCType(),
            ),
            noiseSuppressionOptions: LKRTCAudioProcessingComponentOptions(
                enabled: noiseSuppression,
                mode: noiseSuppressionMode.toRTCType(),
            ),
            autoGainControlOptions: LKRTCAudioProcessingComponentOptions(
                enabled: autoGainControl,
                mode: autoGainControlMode.toRTCType(),
            ),
            highPassFilterOptions: LKRTCAudioProcessingComponentOptions(
                enabled: highPassFilter,
                mode: highPassFilterMode.toRTCType(),
            ),
        )
    }
}

extension LKRTCAudioProcessingComponentState {
    func toLKType() -> AudioProcessingComponentState {
        AudioProcessingComponentState(
            requested: requested.map {
                AudioProcessingComponentRequest(isEnabled: $0.isEnabled, mode: $0.mode.toLKType())
            },
            isSoftwareResolved: isSoftwareResolved,
            isSoftwareActive: isSoftwareActive,
            isPlatformAvailable: isPlatformAvailable,
            isPlatformResolved: isPlatformResolved,
            isPlatformActive: isPlatformActive,
            effective: effective.toLKType(),
        )
    }
}

extension LKRTCAudioProcessingState {
    func toLKType() -> AudioProcessingState {
        AudioProcessingState(
            hasAudioProcessingModule: hasAudioProcessingModule,
            echoCancellation: echoCancellation.toLKType(),
            noiseSuppression: noiseSuppression.toLKType(),
            autoGainControl: autoGainControl.toLKType(),
            highPassFilter: highPassFilter.toLKType(),
        )
    }
}

extension LKRTCPlatformAudioProcessingTopology {
    func toLKType() -> PlatformAudioProcessingTopology {
        switch self {
        case .independent: .independent
        case .echoCancellationAndNoiseSuppressionCoupled: .echoCancellationAndNoiseSuppressionCoupled
        @unknown default: .independent
        }
    }
}

extension LKRTCPlatformAudioProcessingComponentState {
    func toLKType() -> PlatformAudioProcessingComponentState {
        PlatformAudioProcessingComponentState(
            isAvailable: isAvailable,
            isRequested: isRequested,
            isActive: isActive,
        )
    }
}

extension LKRTCPlatformAudioProcessingState {
    func toLKType() -> PlatformAudioProcessingState {
        PlatformAudioProcessingState(
            topology: topology.toLKType(),
            echoCancellation: echoCancellation.toLKType(),
            noiseSuppression: noiseSuppression.toLKType(),
            autoGainControl: autoGainControl.toLKType(),
            isVoiceProcessingEnabledRequested: isVoiceProcessingEnabledRequested,
            isVoiceProcessingBypassedRequested: isVoiceProcessingBypassedRequested,
            isVoiceProcessingAGCEnabledRequested: isVoiceProcessingAGCEnabledRequested,
            isVoiceProcessingEnabledActive: isVoiceProcessingEnabledActive,
            isVoiceProcessingBypassedActive: isVoiceProcessingBypassedActive,
            isVoiceProcessingAGCEnabledActive: isVoiceProcessingAGCEnabledActive,
        )
    }
}
