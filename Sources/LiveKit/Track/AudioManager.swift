/*
 * Copyright 2024 LiveKit
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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

// Wrapper for LKRTCAudioBuffer
@objc
public class LKAudioBuffer: NSObject {
    private let _audioBuffer: LKRTCAudioBuffer

    @objc
    public var channels: Int { _audioBuffer.channels }

    @objc
    public var frames: Int { _audioBuffer.frames }

    @objc
    public var framesPerBand: Int { _audioBuffer.framesPerBand }

    @objc
    public var bands: Int { _audioBuffer.bands }

    @objc
    @available(*, deprecated, renamed: "rawBuffer(forChannel:)")
    public func rawBuffer(for channel: Int) -> UnsafeMutablePointer<Float> {
        _audioBuffer.rawBuffer(forChannel: channel)
    }

    @objc
    public func rawBuffer(forChannel channel: Int) -> UnsafeMutablePointer<Float> {
        _audioBuffer.rawBuffer(forChannel: channel)
    }

    init(audioBuffer: LKRTCAudioBuffer) {
        _audioBuffer = audioBuffer
    }
}

// Audio Session Configuration related
public class AudioManager: Loggable {
    // MARK: - Public

    #if compiler(>=6.0)
    public nonisolated(unsafe) static let shared = AudioManager()
    #else
    public static let shared = AudioManager()
    #endif

    public typealias ConfigureAudioSessionFunc = (_ newState: State,
                                                  _ oldState: State) -> Void

    public typealias DeviceUpdateFunc = (_ audioManager: AudioManager) -> Void

    /// Use this to provide a custom func to configure the audio session instead of ``defaultConfigureAudioSessionFunc(newState:oldState:)``.
    /// This method should not block and is expected to return immediately.
    public var customConfigureAudioSessionFunc: ConfigureAudioSessionFunc? {
        get { _state.customConfigureFunc }
        set { _state.mutate { $0.customConfigureFunc = newValue } }
    }

    public enum TrackState {
        case none
        case localOnly
        case remoteOnly
        case localAndRemote
    }

    public struct State: Equatable {
        // Only consider State mutated when public vars change
        public static func == (lhs: AudioManager.State, rhs: AudioManager.State) -> Bool {
            lhs.localTracksCount == rhs.localTracksCount &&
                lhs.remoteTracksCount == rhs.remoteTracksCount &&
                lhs.isSpeakerOutputPreferred == rhs.isSpeakerOutputPreferred
        }

        // Keep this var within State so it's protected by UnfairLock
        var customConfigureFunc: ConfigureAudioSessionFunc?

        public var localTracksCount: Int = 0
        public var remoteTracksCount: Int = 0
        public var isSpeakerOutputPreferred: Bool = true

        public var trackState: TrackState {
            if localTracksCount > 0, remoteTracksCount == 0 {
                return .localOnly
            } else if localTracksCount == 0, remoteTracksCount > 0 {
                return .remoteOnly
            } else if localTracksCount > 0, remoteTracksCount > 0 {
                return .localAndRemote
            }

            return .none
        }
    }

    /// Set this to false if you prefer using the device's receiver instead of speaker. Defaults to true.
    /// This only works when the audio output is set to the built-in speaker / receiver.
    public var isSpeakerOutputPreferred: Bool {
        get { _state.isSpeakerOutputPreferred }
        set { _state.mutate { $0.isSpeakerOutputPreferred = newValue } }
    }

    // MARK: - AudioProcessingModule

    private lazy var capturePostProcessingDelegateAdapter: AudioCustomProcessingDelegateAdapter = {
        let adapter = AudioCustomProcessingDelegateAdapter(target: nil)
        RTC.audioProcessingModule.capturePostProcessingDelegate = adapter
        return adapter
    }()

    private lazy var renderPreProcessingDelegateAdapter: AudioCustomProcessingDelegateAdapter = {
        let adapter = AudioCustomProcessingDelegateAdapter(target: nil)
        RTC.audioProcessingModule.renderPreProcessingDelegate = adapter
        return adapter
    }()

    let capturePostProcessingDelegateSubject = CurrentValueSubject<AudioCustomProcessingDelegate?, Never>(nil)

    public var capturePostProcessingDelegate: AudioCustomProcessingDelegate? {
        get { capturePostProcessingDelegateAdapter.target }
        set {
            capturePostProcessingDelegateAdapter.set(target: newValue)
            capturePostProcessingDelegateSubject.send(newValue)
        }
    }

    public var renderPreProcessingDelegate: AudioCustomProcessingDelegate? {
        get { renderPreProcessingDelegateAdapter.target }
        set { renderPreProcessingDelegateAdapter.set(target: newValue) }
    }

    // MARK: - AudioDeviceModule

    public let defaultOutputDevice = AudioDevice(ioDevice: LKRTCIODevice.defaultDevice(with: .output))

    public let defaultInputDevice = AudioDevice(ioDevice: LKRTCIODevice.defaultDevice(with: .input))

    public var outputDevices: [AudioDevice] {
        RTC.audioDeviceModule.outputDevices.map { AudioDevice(ioDevice: $0) }
    }

    public var inputDevices: [AudioDevice] {
        RTC.audioDeviceModule.inputDevices.map { AudioDevice(ioDevice: $0) }
    }

    public var outputDevice: AudioDevice {
        get { AudioDevice(ioDevice: RTC.audioDeviceModule.outputDevice) }
        set { RTC.audioDeviceModule.outputDevice = newValue._ioDevice }
    }

    public var inputDevice: AudioDevice {
        get { AudioDevice(ioDevice: RTC.audioDeviceModule.inputDevice) }
        set { RTC.audioDeviceModule.inputDevice = newValue._ioDevice }
    }

    public var onDeviceUpdate: DeviceUpdateFunc? {
        didSet {
            RTC.audioDeviceModule.setDevicesUpdatedHandler { [weak self] in
                guard let self else { return }
                self.onDeviceUpdate?(self)
            }
        }
    }

    // MARK: - Internal

    var localTracksCount: Int { _state.localTracksCount }

    var remoteTracksCount: Int { _state.remoteTracksCount }

    enum `Type` {
        case local
        case remote
    }

    // MARK: - Private

    private var _state = StateSync(State())

    // Singleton
    private init() {
        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in
            guard let self else { return }

            self.log("\(oldState) -> \(newState)")

            #if os(iOS)
            let configureFunc = newState.customConfigureFunc ?? self.defaultConfigureAudioSessionFunc
            configureFunc(newState, oldState)
            #endif
        }
    }

    func trackDidStart(_ type: Type) {
        // async mutation
        _state.mutate { state in
            if type == .local { state.localTracksCount += 1 }
            if type == .remote { state.remoteTracksCount += 1 }
        }
    }

    func trackDidStop(_ type: Type) {
        // async mutation
        _state.mutate { state in
            if type == .local { state.localTracksCount -= 1 }
            if type == .remote { state.remoteTracksCount -= 1 }
        }
    }

    #if os(iOS)
    /// The default implementation when audio session configuration is requested by the SDK.
    /// Configure the `RTCAudioSession` of `WebRTC` framework.
    ///
    /// > Note: It is recommended to use `RTCAudioSessionConfiguration.webRTC()` to obtain an instance of `RTCAudioSessionConfiguration` instead of instantiating directly.
    ///
    /// - Parameters:
    ///   - configuration: A configured RTCAudioSessionConfiguration
    ///   - setActive: passing true/false will call `AVAudioSession.setActive` internally
    public func defaultConfigureAudioSessionFunc(newState: State, oldState: State) {
        DispatchQueue.liveKitWebRTC.async { [weak self] in

            guard let self else { return }

            // prepare config
            let configuration = LKRTCAudioSessionConfiguration.webRTC()

            if newState.trackState == .remoteOnly && newState.isSpeakerOutputPreferred {
                /* .playback */
                configuration.category = AVAudioSession.Category.playback.rawValue
                configuration.mode = AVAudioSession.Mode.spokenAudio.rawValue
                configuration.categoryOptions = [
                    .mixWithOthers,
                ]

            } else if [.localOnly, .localAndRemote].contains(newState.trackState) ||
                (newState.trackState == .remoteOnly && !newState.isSpeakerOutputPreferred)
            {
                /* .playAndRecord */
                configuration.category = AVAudioSession.Category.playAndRecord.rawValue

                if newState.isSpeakerOutputPreferred {
                    // use .videoChat if speakerOutput is preferred
                    configuration.mode = AVAudioSession.Mode.videoChat.rawValue
                } else {
                    // use .voiceChat if speakerOutput is not preferred
                    configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
                }

                configuration.categoryOptions = [
                    .allowBluetooth,
                    .allowBluetoothA2DP,
                    .allowAirPlay,
                ]

            } else {
                /* .soloAmbient */
                configuration.category = AVAudioSession.Category.soloAmbient.rawValue
                configuration.mode = AVAudioSession.Mode.default.rawValue
                configuration.categoryOptions = []
            }

            var setActive: Bool?

            if newState.trackState != .none, oldState.trackState == .none {
                // activate audio session when there is any local/remote audio track
                setActive = true
            } else if newState.trackState == .none, oldState.trackState != .none {
                // deactivate audio session when there are no more local/remote audio tracks
                setActive = false
            }

            // configure session
            let session = LKRTCAudioSession.sharedInstance()
            session.lockForConfiguration()
            // always unlock
            defer { session.unlockForConfiguration() }

            do {
                self.log("configuring audio session category: \(configuration.category), mode: \(configuration.mode), setActive: \(String(describing: setActive))")

                if let setActive {
                    try session.setConfiguration(configuration, active: setActive)
                } else {
                    try session.setConfiguration(configuration)
                }

            } catch {
                self.log("Failed to configure audio session with error: \(error)", .error)
            }
        }
    }
    #endif
}

public extension AudioManager {
    /// Add an ``AudioRenderer`` to receive pcm buffers from local input (mic).
    /// Only ``AudioRenderer/render(pcmBuffer:)`` will be called.
    /// Usage: `AudioManager.shared.add(localAudioRenderer: localRenderer)`
    func add(localAudioRenderer delegate: AudioRenderer) {
        capturePostProcessingDelegateAdapter.audioRenderers.add(delegate: delegate)
    }

    func remove(localAudioRenderer delegate: AudioRenderer) {
        capturePostProcessingDelegateAdapter.audioRenderers.remove(delegate: delegate)
    }
}

public extension AudioManager {
    /// Add an ``AudioRenderer`` to receive pcm buffers from combined remote audio.
    /// Only ``AudioRenderer/render(pcmBuffer:)`` will be called.
    /// To receive buffer for individual tracks, use ``RemoteAudioTrack/add(audioRenderer:)`` instead.
    /// Usage: `AudioManager.shared.add(remoteAudioRenderer: localRenderer)`
    func add(remoteAudioRenderer delegate: AudioRenderer) {
        renderPreProcessingDelegateAdapter.audioRenderers.add(delegate: delegate)
    }

    func remove(remoteAudioRenderer delegate: AudioRenderer) {
        renderPreProcessingDelegateAdapter.audioRenderers.remove(delegate: delegate)
    }
}
