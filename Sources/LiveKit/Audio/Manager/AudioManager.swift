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

    private lazy var capturePostProcessingDelegateAdapter: AudioCustomProcessingDelegateAdapter = {
        let adapter = AudioCustomProcessingDelegateAdapter(label: "capturePost")
        RTC.audioProcessingModule.capturePostProcessingDelegate = adapter
        return adapter
    }()

    private lazy var renderPreProcessingDelegateAdapter: AudioCustomProcessingDelegateAdapter = {
        let adapter = AudioCustomProcessingDelegateAdapter(label: "renderPre")
        RTC.audioProcessingModule.renderPreProcessingDelegate = adapter
        return adapter
    }()

    let capturePostProcessingDelegateSubject = CurrentValueSubject<AudioCustomProcessingDelegate?, Never>(nil)

    /// Add a delegate to modify the local audio buffer before it is sent to the network
    /// - Note: Only one delegate can be set at a time, but you can create one to wrap others if needed
    /// - Note: If you only need to observe the buffer (rather than modify it), use ``add(localAudioRenderer:)`` instead
    public var capturePostProcessingDelegate: AudioCustomProcessingDelegate? {
        get { capturePostProcessingDelegateAdapter.target }
        set {
            capturePostProcessingDelegateAdapter.set(target: newValue)
            capturePostProcessingDelegateSubject.send(newValue)
        }
    }

    /// Add a delegate to modify the combined remote audio buffer (all tracks) before it is played to the user
    /// - Note: Only one delegate can be set at a time, but you can create one to wrap others if needed
    /// - Note: If you only need to observe the buffer (rather than modify it), use ``add(remoteAudioRenderer:)`` instead
    /// - Note: If you need to observe the buffer for individual tracks, use ``RemoteAudioTrack/add(audioRenderer:)`` instead
    public var renderPreProcessingDelegate: AudioCustomProcessingDelegate? {
        get { renderPreProcessingDelegateAdapter.target }
        set { renderPreProcessingDelegateAdapter.set(target: newValue) }
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

    /// Enables advanced ducking which ducks other audio based on the presence of voice activity from local and remote chat participants.
    /// Default: true.
    public var isAdvancedDuckingEnabled: Bool {
        get { RTC.audioDeviceModule.isAdvancedDuckingEnabled }
        set { RTC.audioDeviceModule.isAdvancedDuckingEnabled = newValue }
    }

    /// The ducking(audio reducing) level of other audio.
    @available(iOS 17, macOS 14.0, visionOS 1.0, *)
    public var duckingLevel: AudioDuckingLevel {
        get { AudioDuckingLevel(rawValue: RTC.audioDeviceModule.duckingLevel) ?? .default }
        set { RTC.audioDeviceModule.duckingLevel = newValue.rawValue }
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

    /// Enables manual-rendering (no-device) mode of AVAudioEngine.
    /// Currently experimental.
    public var isManualRenderingMode: Bool { RTC.audioDeviceModule.isManualRenderingMode }

    public func setManualRenderingMode(_ enabled: Bool) throws {
        let result = RTC.audioDeviceModule.setManualRenderingMode(enabled)
        try checkAdmResult(code: result)
    }

    // MARK: - Recording

    /// Keep recording initialized (mic input) and pre-warm voice processing etc.
    /// Mic permission is required and dialog will appear if not already granted.
    /// This will per persisted accross Rooms and connections.
    public var isRecordingAlwaysPreparedMode: Bool { RTC.audioDeviceModule.isRecordingAlwaysPreparedMode }

    /// Keep recording initialized (mic input) and pre-warm voice processing etc.
    /// Mic permission is required and dialog will appear if not already granted.
    /// This will per persisted accross Rooms and connections.
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

let kAudioEngineErrorInsufficientDevicePermission = -4101
let kAudioEngineErrorAudioSessionCategoryRecordingRequired = -4102

extension AudioManager {
    func checkAdmResult(code: Int) throws {
        if code == kAudioEngineErrorFailedToConfigureAudioSession {
            throw LiveKitError(.audioSession, message: "Failed to configure audio session")
        } else if code == kAudioEngineErrorInsufficientDevicePermission {
            throw LiveKitError(.deviceAccessDenied, message: "Device permissions are not granted")
        } else if code != 0 {
            throw LiveKitError(.audioEngine, message: "Audio engine returned error code: \(code)")
        }
    }
}
