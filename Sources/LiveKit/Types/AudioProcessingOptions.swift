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

public enum AudioProcessingImplementation: Int, Sendable {
    case unknown
    case disabled
    case software
    case platform
    case softwareAndPlatform
}

/// A successful outcome of applying ``AudioProcessingOptions``.
public enum AudioProcessingOptionsResult: Sendable {
    /// Options were applied immediately by the component handling the request.
    case applied
    /// Options were accepted and stored. Active senders reapply them separately.
    case stored
}

/// Immutable runtime voice-processing settings.
///
/// The default initializer produces the SDK's communication profile: echo
/// cancellation, gain control and noise suppression enabled in `.automatic`
/// mode, high-pass filter disabled.
public struct AudioProcessingOptions: Hashable, Sendable {
    public static let noProcessing = AudioProcessingOptions(
        echoCancellation: false,
        autoGainControl: false,
        noiseSuppression: false,
        highpassFilter: false,
    )

    public let echoCancellation: Bool
    public let autoGainControl: Bool
    public let noiseSuppression: Bool
    public let highpassFilter: Bool

    public let echoCancellationMode: EchoCancellationMode
    public let autoGainControlMode: AutoGainControlMode
    public let noiseSuppressionMode: NoiseSuppressionMode
    public let highpassFilterMode: HighpassFilterMode

    public init(
        echoCancellation: Bool = true,
        autoGainControl: Bool = true,
        noiseSuppression: Bool = true,
        highpassFilter: Bool = false,
        echoCancellationMode: EchoCancellationMode = .automatic,
        autoGainControlMode: AutoGainControlMode = .automatic,
        noiseSuppressionMode: NoiseSuppressionMode = .automatic,
        highpassFilterMode: HighpassFilterMode = .automatic,
    ) {
        self.echoCancellation = echoCancellation
        self.autoGainControl = autoGainControl
        self.noiseSuppression = noiseSuppression
        self.highpassFilter = highpassFilter
        self.echoCancellationMode = echoCancellationMode
        self.autoGainControlMode = autoGainControlMode
        self.noiseSuppressionMode = noiseSuppressionMode
        self.highpassFilterMode = highpassFilterMode
    }
}

extension AudioProcessingOptions {
    /// Whether these options request Apple's coupled voice processing path.
    ///
    /// Mirrors the coupled AEC/NS resolution: any enabled echo cancellation or
    /// noise suppression component that is not forced to software prefers the
    /// platform path when it is available.
    var requestsPlatformEchoNoisePath: Bool {
        (echoCancellation && echoCancellationMode != .software) ||
            (noiseSuppression && noiseSuppressionMode != .software)
    }
}

/// The caller's request for one audio processing component: enabled flag plus
/// implementation mode.
public struct AudioProcessingComponentRequest<Mode: Sendable>: Sendable {
    /// Whether the component was requested to be enabled.
    public let isEnabled: Bool

    /// The requested implementation mode.
    public let mode: Mode
}

/// Resolved and live state of one processing path (WebRTC software APM or the
/// platform implementation) for an audio processing component.
public struct AudioProcessingPathState: Sendable {
    /// Whether the resolver decided this path should run, after weighing the
    /// requested mode against platform availability, coupling, and policy.
    public let isResolved: Bool

    /// Whether this path reports the component as currently running.
    public let isActive: Bool
}

/// Diagnostic state of one audio processing component (echo cancellation,
/// noise suppression, auto gain control or high-pass filter), observed at
/// three stages of one pipeline: requested (caller intent) -> resolved (the
/// engine's per-path decision) -> active (live truth), with ``effective`` as
/// the merged verdict.
public struct AudioProcessingComponentState<Mode: Sendable>: Sendable {
    /// What the caller most recently requested for this component. `nil` when
    /// no audio processing options have ever been applied — "nobody asked".
    public let requested: AudioProcessingComponentRequest<Mode>?

    /// The WebRTC software (APM) path.
    public let software: AudioProcessingPathState

    /// The platform path, or `nil` when this device/OS offers no built-in
    /// implementation. The OS owns this path's outcome: it can decline, defer,
    /// or couple components even after the engine requests it.
    public let platform: AudioProcessingPathState?

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
/// detail lives on ``PlatformVoiceProcessingState`` instead.
public struct AudioProcessingState: Sendable {
    /// Echo-cancellation state and its most recent typed request.
    public let echoCancellation: AudioProcessingComponentState<EchoCancellationMode>

    /// Noise-suppression state and its most recent typed request.
    public let noiseSuppression: AudioProcessingComponentState<NoiseSuppressionMode>

    /// Automatic-gain-control state and its most recent typed request.
    public let autoGainControl: AudioProcessingComponentState<AutoGainControlMode>

    /// High-pass-filter state and its most recent typed request.
    public let highpassFilter: AudioProcessingComponentState<HighpassFilterMode>
}

public enum PlatformVoiceProcessingTopology: Int, Sendable {
    case independent
    case echoCancellationAndNoiseSuppressionCoupled
}

public struct PlatformVoiceProcessingComponentState: Sendable {
    /// Whether the device offers this effect at all.
    public let isAvailable: Bool
    /// The last state requested from the audio device module.
    public let isRequested: Bool
    /// Live OS readback when the audio device module can query the effect.
    public let isActive: Bool
}

/// Requested and live state of one Apple Voice Processing I/O unit flag.
public struct PlatformVoiceProcessingFlagState: Sendable {
    /// The last state requested from the audio device module.
    public let isRequested: Bool
    /// Live readback from the platform input node. Reads `false` before input
    /// is configured or where the value is not observable.
    public let isActive: Bool
}

/// Device-level snapshot of Apple's platform Voice Processing I/O.
public struct PlatformVoiceProcessingState: Sendable {
    public let topology: PlatformVoiceProcessingTopology
    public let echoCancellation: PlatformVoiceProcessingComponentState
    public let noiseSuppression: PlatformVoiceProcessingComponentState
    public let autoGainControl: PlatformVoiceProcessingComponentState
    /// Whether the Voice Processing I/O unit is enabled.
    public let voiceProcessingEnabled: PlatformVoiceProcessingFlagState
    /// Whether the Voice Processing I/O unit is bypassed.
    public let voiceProcessingBypassed: PlatformVoiceProcessingFlagState
    /// Whether the Voice Processing I/O unit's automatic gain control is enabled.
    public let voiceProcessingAGCEnabled: PlatformVoiceProcessingFlagState
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

extension LKRTCAudioProcessingOptionsResult {
    /// Partitions the upstream result: successes are returned, rejections are thrown.
    func toLKType() throws -> AudioProcessingOptionsResult {
        switch code {
        case .applied: return .applied
        case .stored: return .stored
        case .rejectedRemoteTrack: throw AudioProcessingOptionsError(code: .invalidState, message: message)
        case .rejectedInvalidCombination: throw AudioProcessingOptionsError(code: .invalidCombination, message: message)
        case .rejectedPlatformUnavailable: throw AudioProcessingOptionsError(code: .platformUnavailable, message: message)
        case .applyFailed: throw AudioProcessingOptionsError(code: .applyFailed, message: message)
        @unknown default: throw AudioProcessingOptionsError(code: .applyFailed, message: message)
        }
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
                enabled: highpassFilter,
                mode: highpassFilterMode.toRTCType(),
            ),
        )
    }
}

extension LKRTCAudioProcessingComponentState {
    func toLKType<Mode: AudioProcessingModeConvertible>(modeType _: Mode.Type) -> AudioProcessingComponentState<Mode> {
        AudioProcessingComponentState(
            requested: requested.map {
                AudioProcessingComponentRequest(isEnabled: $0.isEnabled, mode: Mode.fromRTCType($0.mode))
            },
            software: AudioProcessingPathState(
                isResolved: isSoftwareResolved,
                isActive: isSoftwareActive,
            ),
            platform: isPlatformAvailable ? AudioProcessingPathState(
                isResolved: isPlatformResolved,
                isActive: isPlatformActive,
            ) : nil,
            effective: effective.toLKType(),
        )
    }
}

extension LKRTCAudioProcessingState {
    func toLKType() -> AudioProcessingState {
        AudioProcessingState(
            echoCancellation: echoCancellation.toLKType(modeType: EchoCancellationMode.self),
            noiseSuppression: noiseSuppression.toLKType(modeType: NoiseSuppressionMode.self),
            autoGainControl: autoGainControl.toLKType(modeType: AutoGainControlMode.self),
            highpassFilter: highPassFilter.toLKType(modeType: HighpassFilterMode.self),
        )
    }
}

extension LKRTCPlatformAudioProcessingTopology {
    func toLKType() -> PlatformVoiceProcessingTopology {
        switch self {
        case .independent: .independent
        case .echoCancellationAndNoiseSuppressionCoupled: .echoCancellationAndNoiseSuppressionCoupled
        @unknown default: .independent
        }
    }
}

extension LKRTCPlatformAudioProcessingComponentState {
    func toLKType() -> PlatformVoiceProcessingComponentState {
        PlatformVoiceProcessingComponentState(
            isAvailable: isAvailable,
            isRequested: isRequested,
            isActive: isActive,
        )
    }
}

extension LKRTCPlatformAudioProcessingState {
    func toLKType() -> PlatformVoiceProcessingState {
        PlatformVoiceProcessingState(
            topology: topology.toLKType(),
            echoCancellation: echoCancellation.toLKType(),
            noiseSuppression: noiseSuppression.toLKType(),
            autoGainControl: autoGainControl.toLKType(),
            voiceProcessingEnabled: PlatformVoiceProcessingFlagState(
                isRequested: isVoiceProcessingEnabledRequested,
                isActive: isVoiceProcessingEnabledActive,
            ),
            voiceProcessingBypassed: PlatformVoiceProcessingFlagState(
                isRequested: isVoiceProcessingBypassedRequested,
                isActive: isVoiceProcessingBypassedActive,
            ),
            voiceProcessingAGCEnabled: PlatformVoiceProcessingFlagState(
                isRequested: isVoiceProcessingAGCEnabledRequested,
                isActive: isVoiceProcessingAGCEnabledActive,
            ),
        )
    }
}
