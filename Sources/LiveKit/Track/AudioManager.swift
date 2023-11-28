/*
 * Copyright 2022 LiveKit
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
import WebRTC

// Audio Session Configuration related
public class AudioManager: Loggable {

    // MARK: - Public

    public static let shared = AudioManager()

    public typealias ConfigureAudioSessionFunc = (_ newState: State,
                                                  _ oldState: State) -> Void

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
                lhs.preferSpeakerOutput == rhs.preferSpeakerOutput
        }

        // Keep this var within State so it's protected by UnfairLock
        internal var customConfigureFunc: ConfigureAudioSessionFunc?

        public var localTracksCount: Int = 0
        public var remoteTracksCount: Int = 0
        public var preferSpeakerOutput: Bool = true

        public var trackState: TrackState {

            if localTracksCount > 0 && remoteTracksCount == 0 {
                return .localOnly
            } else if localTracksCount == 0 && remoteTracksCount > 0 {
                return .remoteOnly
            } else if localTracksCount > 0 && remoteTracksCount > 0 {
                return .localAndRemote
            }

            return .none
        }
    }

    /// Set this to false if you prefer using the device's receiver instead of speaker. Defaults to true.
    /// This only works when the audio output is set to the built-in speaker / receiver.
    public var preferSpeakerOutput: Bool {
        get { _state.preferSpeakerOutput }
        set { _state.mutate { $0.preferSpeakerOutput = newValue } }
    }

    // MARK: - Internal

    internal var localTracksCount: Int { _state.localTracksCount }

    internal var remoteTracksCount: Int { _state.remoteTracksCount }

    internal enum `Type` {
        case local
        case remote
    }

    // MARK: - Private

    private var _state = StateSync(State())

    // Singleton
    private init() {
        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in
            guard let self = self else { return }

            self.log("\(oldState) -> \(newState)")

            #if os(iOS)
            let configureFunc = newState.customConfigureFunc ?? defaultConfigureAudioSessionFunc
            configureFunc(newState, oldState)
            #endif
        }
    }

    internal func trackDidStart(_ type: Type) {
        // async mutation
        _state.mutate { state in
            if type == .local { state.localTracksCount += 1 }
            if type == .remote { state.remoteTracksCount += 1 }
        }
    }

    internal func trackDidStop(_ type: Type) {
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

            guard let self = self else { return }

            // prepare config
            let configuration = RTCAudioSessionConfiguration.webRTC()

            if newState.trackState == .remoteOnly && newState.preferSpeakerOutput {
                /* .playback */
                configuration.category = AVAudioSession.Category.playback.rawValue
                configuration.mode = AVAudioSession.Mode.spokenAudio.rawValue
                configuration.categoryOptions = [
                    .mixWithOthers
                ]

            } else if [.localOnly, .localAndRemote].contains(newState.trackState) ||
                        (newState.trackState == .remoteOnly && !newState.preferSpeakerOutput) {

                /* .playAndRecord */
                configuration.category = AVAudioSession.Category.playAndRecord.rawValue

                if newState.preferSpeakerOutput {
                    // use .videoChat if speakerOutput is preferred
                    configuration.mode = AVAudioSession.Mode.videoChat.rawValue
                } else {
                    // use .voiceChat if speakerOutput is not preferred
                    configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
                }

                configuration.categoryOptions = [
                    .allowBluetooth,
                    .allowBluetoothA2DP,
                    .allowAirPlay
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
            let session = RTCAudioSession.sharedInstance()
            session.lockForConfiguration()
            // always unlock
            defer { session.unlockForConfiguration() }

            do {
                self.log("configuring audio session category: \(configuration.category), mode: \(configuration.mode), setActive: \(String(describing: setActive))")

                if let setActive = setActive {
                    try session.setConfiguration(configuration, active: setActive)
                } else {
                    try session.setConfiguration(configuration)
                }

            } catch let error {
                self.log("Failed to configure audio session with error: \(error)", .error)
            }
        }
    }
    #endif
}
