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

// swiftlint:disable file_length

import Accelerate
import AVFoundation
import Combine

internal import LiveKitWebRTC

// Audio Session Configuration related
public class AudioManager: Loggable {
    // MARK: - Public

    #if swift(>=6.0)
    public nonisolated(unsafe) static let shared = AudioManager()
    #else
    public static let shared = AudioManager()
    #endif

    public static func prepare() {
        // Instantiate shared instance
        _ = shared
    }

    public typealias OnDevicesDidUpdate = @Sendable (_ audioManager: AudioManager) -> Void

    public typealias OnSpeechActivity = @Sendable (_ audioManager: AudioManager, _ event: SpeechActivityEvent) -> Void

    #if os(iOS) || os(visionOS) || os(tvOS)

    @available(*, deprecated)
    public typealias ConfigureAudioSessionFunc = @Sendable (_ newState: State,
                                                            _ oldState: State) -> Void

    /// Use this to provide a custom function to configure the audio session, overriding the default behavior
    /// provided by ``defaultConfigureAudioSessionFunc(newState:oldState:)``.
    ///
    /// - Important: This method should return immediately and must not block.
    /// - Note: Once set, the following properties will no longer be effective:
    ///   - ``sessionConfiguration``
    ///   - ``isSpeakerOutputPreferred``
    ///
    /// If you want to revert to default behavior, set this to `nil`.
    @available(*, deprecated, message: "Use `set(engineObservers:)` instead. See `AudioSessionEngineObserver` for example.")
    public var customConfigureAudioSessionFunc: ConfigureAudioSessionFunc? {
        get { _state.customConfigureFunc }
        set { _state.mutate { $0.customConfigureFunc = newValue } }
    }

    /// Determines whether the device's built-in speaker or receiver is preferred for audio output.
    ///
    /// - Defaults to `true`, indicating that the speaker is preferred.
    /// - Set to `false` if the receiver is preferred instead of the speaker.
    /// - Note: This property only applies when the audio output is routed to the built-in speaker or receiver.
    ///
    /// This property is ignored if ``customConfigureAudioSessionFunc`` is set.
    public var isSpeakerOutputPreferred: Bool {
        get { audioSession.isSpeakerOutputPreferred }
        set { audioSession.isSpeakerOutputPreferred = newValue }
    }

    /// Specifies a fixed configuration for the audio session, overriding dynamic adjustments.
    ///
    /// If this property is set, it will take precedence over any dynamic configuration logic, including
    /// the value of ``isSpeakerOutputPreferred``.
    ///
    /// This property is ignored if ``customConfigureAudioSessionFunc`` is set.
    public var sessionConfiguration: AudioSessionConfiguration? {
        get { _state.sessionConfiguration }
        set { _state.mutate { $0.sessionConfiguration = newValue } }
    }

    @available(*, deprecated)
    public enum TrackState {
        case none
        case localOnly
        case remoteOnly
        case localAndRemote
    }
    #endif

    public struct State: @unchecked Sendable {
        var engineObservers = [any AudioEngineObserver]()
        var onDevicesDidUpdate: OnDevicesDidUpdate?
        var onMutedSpeechActivity: OnSpeechActivity?

        #if os(iOS) || os(visionOS) || os(tvOS)
        // Keep this var within State so it's protected by UnfairLock
        public var localTracksCount: Int = 0
        public var remoteTracksCount: Int = 0
        public var customConfigureFunc: ConfigureAudioSessionFunc?
        public var sessionConfiguration: AudioSessionConfiguration?

        public var trackState: TrackState {
            switch (localTracksCount > 0, remoteTracksCount > 0) {
            case (true, false): .localOnly
            case (false, true): .remoteOnly
            case (true, true): .localAndRemote
            default: .none
            }
        }
        #endif
    }

    // MARK: - AudioProcessingModule

    private lazy var capturePostProcessingDelegateAdapter = AudioCustomProcessingDelegateAdapter(
        label: "capturePost",
        rtcDelegateSetter: { RTC.audioProcessingModule.capturePostProcessingDelegate = $0 }
    )

    private lazy var renderPreProcessingDelegateAdapter = AudioCustomProcessingDelegateAdapter(
        label: "renderPre",
        rtcDelegateSetter: { RTC.audioProcessingModule.renderPreProcessingDelegate = $0 }
    )

    let capturePostProcessingDelegateSubject = CurrentValueSubject<AudioCustomProcessingDelegate?, Never>(nil)

    /// Add a delegate to modify the local audio buffer before it is sent to the network
    /// - Note: Only one delegate can be set at a time, but you can create one to wrap others if needed
    /// - Note: If you only need to observe the buffer (rather than modify it), use ``add(localAudioRenderer:)`` instead
    public var capturePostProcessingDelegate: AudioCustomProcessingDelegate? {
        didSet {
            capturePostProcessingDelegateAdapter.set(target: capturePostProcessingDelegate, oldTarget: oldValue)
            capturePostProcessingDelegateSubject.send(capturePostProcessingDelegate)
        }
    }

    /// Add a delegate to modify the combined remote audio buffer (all tracks) before it is played to the user
    /// - Note: Only one delegate can be set at a time, but you can create one to wrap others if needed
    /// - Note: If you only need to observe the buffer (rather than modify it), use ``add(remoteAudioRenderer:)`` instead
    /// - Note: If you need to observe the buffer for individual tracks, use ``RemoteAudioTrack/add(audioRenderer:)`` instead
    public var renderPreProcessingDelegate: AudioCustomProcessingDelegate? {
        didSet {
            renderPreProcessingDelegateAdapter.set(target: renderPreProcessingDelegate, oldTarget: oldValue)
        }
    }

    // MARK: - AudioDeviceModule

    public let defaultOutputDevice = AudioDevice(ioDevice: LKRTCIODevice.defaultDevice(with: .output))

    public let defaultInputDevice = AudioDevice(ioDevice: LKRTCIODevice.defaultDevice(with: .input))

    public var outputDevices: [AudioDevice] {
        #if os(macOS)
        RTC.audioDeviceModule.outputDevices.map { AudioDevice(ioDevice: $0) }
        #else
        []
        #endif
    }

    public var inputDevices: [AudioDevice] {
        #if os(macOS)
        RTC.audioDeviceModule.inputDevices.map { AudioDevice(ioDevice: $0) }
        #else
        []
        #endif
    }

    public var outputDevice: AudioDevice {
        get {
            #if os(macOS)
            AudioDevice(ioDevice: RTC.audioDeviceModule.outputDevice)
            #else
            AudioDevice(ioDevice: LKRTCIODevice.defaultDevice(with: .output))
            #endif
        }
        set {
            #if os(macOS)
            RTC.audioDeviceModule.outputDevice = newValue._ioDevice
            #endif
        }
    }

    public var inputDevice: AudioDevice {
        get {
            #if os(macOS)
            AudioDevice(ioDevice: RTC.audioDeviceModule.inputDevice)
            #else
            AudioDevice(ioDevice: LKRTCIODevice.defaultDevice(with: .input))
            #endif
        }
        set {
            #if os(macOS)
            RTC.audioDeviceModule.inputDevice = newValue._ioDevice
            #endif
        }
    }

    public var onDeviceUpdate: OnDevicesDidUpdate? {
        get { _state.onDevicesDidUpdate }
        set { _state.mutate { $0.onDevicesDidUpdate = newValue } }
    }

    /// Detect voice activity even if the mic is muted.
    /// Internal audio engine must be initialized by calling ``prepareRecording()`` or
    /// connecting to a room and subscribing to a remote audio track or publishing a local audio track.
    public var onMutedSpeechActivity: OnSpeechActivity? {
        get { _state.onMutedSpeechActivity }
        set { _state.mutate { $0.onMutedSpeechActivity = newValue } }
    }

    /// Enables "advanced ducking" of *other audio* while using Apple's voice processing APIs.
    ///
    /// When enabled, the system dynamically adjusts ducking based on the presence of voice activity from
    /// either side of the call: it applies more ducking when someone is speaking and reduces ducking
    /// when neither side is speaking (SharePlay / FaceTime-like behavior).
    ///
    /// Defaults to `false` (SDK default), which keeps a fixed ducking behavior with minimal ducking.
    /// This is intended to keep other audio as loud as possible by default.
    ///
    /// - Note: This only affects how non-voice audio is reduced. It does not change the level of
    ///   the voice-chat stream itself.
    /// - SeeAlso: ``duckingLevel``
    public var isAdvancedDuckingEnabled: Bool {
        get { RTC.audioDeviceModule.isAdvancedDuckingEnabled }
        set { RTC.audioDeviceModule.isAdvancedDuckingEnabled = newValue }
    }

    /// Controls how much *other audio* is reduced ("ducked") while using Apple's voice processing APIs.
    ///
    /// The level and ``isAdvancedDuckingEnabled`` can be used independently:
    /// - Use higher values (for example ``AudioDuckingLevel/max``) for better voice intelligibility.
    /// - Use lower values (for example ``AudioDuckingLevel/min``) to keep other audio as loud as possible.
    ///
    /// Defaults to ``AudioDuckingLevel/min`` (SDK default), which keeps other audio as loud as possible.
    /// Higher levels are opt-in and trade other-audio loudness for better voice intelligibility.
    ///
    /// ``AudioDuckingLevel/default`` matches Apple's historical fixed ducking amount (not the SDK default).
    @available(iOS 17, macOS 14.0, visionOS 1.0, *)
    public var duckingLevel: AudioDuckingLevel {
        get { RTC.audioDeviceModule.duckingLevel.toLKType() }
        set { RTC.audioDeviceModule.duckingLevel = newValue.toRTCType() }
    }

    /// The main flag that determines whether to enable Voice-Processing I/O of the internal AVAudioEngine. Toggling this requires restarting the AudioEngine.
    /// Setting this to `false` prevents any voice-processing-related initialization, and muted talker detection will not work.
    /// Typically, it is recommended to keep this set to `true` and toggle ``isVoiceProcessingBypassed`` when possible.
    /// Defaults to `true`.
    public var isVoiceProcessingEnabled: Bool { RTC.audioDeviceModule.isVoiceProcessingEnabled }

    public func setVoiceProcessingEnabled(_ enabled: Bool) throws {
        let result = RTC.audioDeviceModule.setVoiceProcessingEnabled(enabled)
        try checkAdmResult(code: result)
    }

    /// Bypass Voice-Processing I/O of internal AVAudioEngine.
    /// It is valid to toggle this at runtime and AudioEngine doesn't require restart.
    /// Defaults to `false`.
    public var isVoiceProcessingBypassed: Bool {
        get {
            if RTC.pcFactoryState.admType == .platformDefault {
                return RTC.pcFactoryState.bypassVoiceProcessing
            }

            return RTC.audioDeviceModule.isVoiceProcessingBypassed
        }
        set {
            guard !(RTC.pcFactoryState.read { $0.isInitialized && $0.admType == .platformDefault }) else {
                log("Cannot set this property after the peer connection has been initialized when using non-AVAudioEngine audio device module", .error)
                return
            }

            RTC.audioDeviceModule.isVoiceProcessingBypassed = newValue
        }
    }

    /// Bypass the Auto Gain Control of internal AVAudioEngine.
    /// It is valid to toggle this at runtime.
    public var isVoiceProcessingAGCEnabled: Bool {
        get { RTC.audioDeviceModule.isVoiceProcessingAGCEnabled }
        set { RTC.audioDeviceModule.isVoiceProcessingAGCEnabled = newValue }
    }

    /// Enables manual rendering (no-device) mode of AVAudioEngine.
    /// In this mode, you can provide audio buffers by calling `AudioManager.shared.mixer.capture(appAudio:)` continuously.
    /// Remote audio will not play out automatically. Get remote mixed audio buffers with `AudioManager.shared.add(localAudioRenderer:)` or individual tracks with ``RemoteAudioTrack/add(audioRenderer:)``.
    public func setManualRenderingMode(_ enabled: Bool) throws {
        let result = RTC.audioDeviceModule.setManualRenderingMode(enabled)
        try checkAdmResult(code: result)
    }

    public var isManualRenderingMode: Bool { RTC.audioDeviceModule.isManualRenderingMode }

    // MARK: - Recording

    /// Whether recording is kept initialized (mic input) for low-latency publish.
    ///
    /// - SeeAlso: ``setRecordingAlwaysPreparedMode(_:)``
    public var isRecordingAlwaysPreparedMode: Bool { RTC.audioDeviceModule.isRecordingAlwaysPreparedMode }

    /// Prepares the microphone capture pipeline for low-latency publishing.
    ///
    /// When enabled, the audio engine is started configured for mic input in a muted state,
    /// which keeps recording initialized and pre-warms voice processing.
    ///
    /// - Parameter enabled: Pass `true` to enable always-prepared recording, or `false` to disable it.
    /// - Note: If `audioSession.isAutomaticConfigurationEnabled` is `true`, the session category is configured to `.playAndRecord`.
    /// - Note: Microphone permission is required. iOS may prompt if not already granted.
    /// - Note: This persists across ``Room`` lifecycles and connections until disabled.
    /// - Throws: An error if the underlying audio device module fails to apply the setting.
    public func setRecordingAlwaysPreparedMode(_ enabled: Bool) async throws {
        let result = RTC.audioDeviceModule.setRecordingAlwaysPreparedMode(enabled)
        try checkAdmResult(code: result)
    }

    /// Starts mic input to the SDK even without any ``Room`` or a connection.
    /// Audio buffers will flow into ``LocalAudioTrack/add(audioRenderer:)`` and ``capturePostProcessingDelegate``.
    public func startLocalRecording() throws {
        // Always unmute APM if muted by last session.
        RTC.audioProcessingModule.isMuted = false // TODO: Possibly not required anymore with new libs
        // Start recording on the ADM.
        let result = RTC.audioDeviceModule.initAndStartRecording()
        try checkAdmResult(code: result)
    }

    /// Stops mic input after it was started with ``startLocalRecording()``
    public func stopLocalRecording() throws {
        let result = RTC.audioDeviceModule.stopRecording()
        try checkAdmResult(code: result)
    }

    /// Sets whether the internal `AVAudioEngine` is allowed to run.
    ///
    /// This flag has the highest priority over any API that may start the engine
    /// (e.g., enabling the mic, ``startLocalRecording()``, or starting playback).
    ///
    /// - Behavior:
    ///   - When set to a disabled availability, the engine will stop if running,
    ///     and it will not start, even if recording or playback is requested.
    ///   - When set back to enabled, the engine will start as soon as possible
    ///     if recording and/or playback had been previously requested while disabled
    ///     (i.e., pending requests are honored once availability allows).
    ///
    /// This is useful when you need to set up connections without touching the audio
    /// device yet (e.g., CallKit flows), or to guarantee the engine remains off
    /// regardless of subscription/publication requests.
    public func setEngineAvailability(_ availability: AudioEngineAvailability) throws {
        let result = RTC.audioDeviceModule.setEngineAvailability(availability.toRTCType())
        try checkAdmResult(code: result)
    }

    public var engineAvailability: AudioEngineAvailability {
        RTC.audioDeviceModule.engineAvailability.toLKType()
    }

    /// Set a chain of ``AudioEngineObserver``s.
    /// Defaults to having a single ``AudioSessionEngineObserver`` initially.
    ///
    /// The first object will be invoked and is responsible for calling the next object.
    /// See ``NextInvokable`` protocol for details.
    ///
    /// Objects set here will be retained.
    public func set(engineObservers: [any AudioEngineObserver]) {
        _state.mutate { $0.engineObservers = engineObservers }
    }

    public var isEngineRunning: Bool {
        RTC.audioDeviceModule.isEngineRunning
    }

    /// The mute state of internal audio engine which uses Voice Processing I/O mute API ``AVAudioInputNode.isVoiceProcessingInputMuted``.
    /// Normally, you do not need to set this manually since it will be handled automatically.
    public var isMicrophoneMuted: Bool {
        get { RTC.audioDeviceModule.isMicrophoneMuted }
        set {
            let result = RTC.audioDeviceModule.setMicrophoneMuted(newValue)
            if result != 0 {
                log("Failed to set microphone muted: \(result)", .error)
            }
        }
    }

    // MARK: - Default AudioEngineObservers

    public let mixer = MixerEngineObserver()

    #if os(iOS) || os(visionOS) || os(tvOS)
    /// Configures the `AVAudioSession` based on the audio engine's state.
    /// Set `AudioManager.shared.audioSession.isAutomaticConfigurationEnabled` to `false` to manually configure the `AVAudioSession` instead.
    /// > Note: It is recommended to set this before connecting to a room.
    public let audioSession = AudioSessionEngineObserver()
    #endif

    // MARK: - Internal

    let _state: StateSync<State>

    let _admDelegateAdapter = AudioDeviceModuleDelegateAdapter()

    init() {
        #if os(iOS) || os(visionOS) || os(tvOS)
        let engineObservers: [any AudioEngineObserver] = [audioSession, mixer]
        #else
        let engineObservers: [any AudioEngineObserver] = [mixer]
        #endif
        _state = StateSync(State(engineObservers: engineObservers))
        _admDelegateAdapter.audioManager = self
        RTC.audioDeviceModule.observer = _admDelegateAdapter
    }
}

public extension AudioManager {
    /// Add an ``AudioRenderer`` to receive pcm buffers from local input (mic).
    /// Only ``AudioRenderer/render(pcmBuffer:)`` will be called.
    /// Usage: `AudioManager.shared.add(localAudioRenderer: localRenderer)`
    func add(localAudioRenderer delegate: AudioRenderer) {
        capturePostProcessingDelegateAdapter.add(delegate: delegate)
    }

    func remove(localAudioRenderer delegate: AudioRenderer) {
        capturePostProcessingDelegateAdapter.remove(delegate: delegate)
    }
}

public extension AudioManager {
    /// Add an ``AudioRenderer`` to receive pcm buffers from combined remote audio.
    /// Only ``AudioRenderer/render(pcmBuffer:)`` will be called.
    /// To receive buffer for individual tracks, use ``RemoteAudioTrack/add(audioRenderer:)`` instead.
    /// Usage: `AudioManager.shared.add(remoteAudioRenderer: localRenderer)`
    func add(remoteAudioRenderer delegate: AudioRenderer) {
        renderPreProcessingDelegateAdapter.add(delegate: delegate)
    }

    func remove(remoteAudioRenderer delegate: AudioRenderer) {
        renderPreProcessingDelegateAdapter.remove(delegate: delegate)
    }
}

extension AudioManager {
    func buildEngineObserverChain() -> (any AudioEngineObserver)? {
        var objects = _state.engineObservers
        guard !objects.isEmpty else { return nil }

        for i in 0 ..< objects.count - 1 {
            objects[i].next = objects[i + 1]
        }

        return objects.first
    }
}

// SDK side AudioEngine error codes
let kAudioEngineErrorFailedToConfigureAudioSession = -4100
let kAudioEngineErrorAudioSessionCategoryRecordingRequired = -4102

let kAudioEngineErrorInsufficientDevicePermission = -4101

extension AudioManager {
    func checkAdmResult(code: Int) throws {
        if code == kAudioEngineErrorFailedToConfigureAudioSession {
            throw LiveKitError(.audioSession, message: "Failed to configure audio session")
        } else if code == kAudioEngineErrorInsufficientDevicePermission {
            throw LiveKitError(.deviceAccessDenied, message: "Device permissions are not granted")
        } else if code == kAudioEngineErrorAudioSessionCategoryRecordingRequired {
            throw LiveKitError(.audioSession, message: "Recording category required for audio session")
        } else if code != 0 {
            throw LiveKitError(.audioEngine, message: "Audio engine returned error code: \(code)")
        }
    }
}
